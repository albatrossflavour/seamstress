# frozen_string_literal: true

require_relative 'app_helper'

describe 'strings_site in directory mode' do
  include AppHelper

  let(:code_dir) { File.join(tmp, 'environments') }

  # An environment laid out the way r10k leaves it.
  def environment(name, deploy: nil, root: File.join(code_dir, name))
    write(File.join(root, 'Puppetfile'), <<~PUPPETFILE)
      mod 'example/stdlib', '9.7.0'
      mod 'app', git: 'git@git.example.com:puppet/app.git', branch: 'main'
    PUPPETFILE
    write(File.join(root, 'site-modules/profile/manifests/init.pp'), manifest('profile'))
    write(File.join(root, 'modules/stdlib/manifests/init.pp'), manifest('stdlib'))
    write(File.join(root, 'modules/stdlib/metadata.json'), JSON.generate('name' => 'example-stdlib', 'version' => '9.7.0'))
    write(File.join(root, 'modules/app/manifests/init.pp'), manifest('app'))
    write(File.join(root, 'modules/app/metadata.json'), JSON.generate('name' => 'example-app', 'version' => '2.0.0'))
    write(File.join(root, 'modules/orphan/manifests/init.pp'), manifest('orphan'))
    write(File.join(root, 'modules/orphan/metadata.json'),
          JSON.generate('name' => 'example-orphan', 'version' => '0.1.0', 'source' => 'https://git.example.com/orphan'))
    write(File.join(root, '.r10k-deploy.json'), JSON.generate(deploy)) if deploy
    root
  end

  def deploy_info(signature, app_sha)
    {
      'name' => 'production', 'signature' => signature, 'started_at' => '2026-11-01T00:00:00Z',
      'finished_at' => '2026-11-01T00:01:00Z', 'deploy_success' => true,
      'module_deploys' => [
        { 'name' => 'stdlib', 'version' => '9.7.0', 'sha' => nil },
        { 'name' => 'app', 'version' => 'main', 'sha' => app_sha }
      ]
    }
  end

  def dir_config(extra = {})
    config({ 'source' => 'directory', 'code_dir' => code_dir }.merge(extra))
  end

  context 'with .r10k-deploy.json' do
    let!(:exit_status) do
      environment('production', deploy: deploy_info('a' * 40, 'b' * 40))
      run_app(dir_config)
    end

    it 'succeeds' do
      expect(exit_status).to eq(0)
    end

    it 'takes provenance from the deploy file' do
      prov = build_json('production')['provenance']
      expect(prov).to include('source' => 'directory', 'commit' => 'a' * 40, 'deployed_at' => '2026-11-01T00:01:00Z',
                              'change_detection' => '.r10k-deploy.json')
      mods = build_json('production')['modules'].to_h { |m| [m['name'], m] }
      expect(mods['app']).to include('kind' => 'git', 'ref' => 'main', 'sha' => 'b' * 40, 'version' => '2.0.0',
                                     'source' => 'git@git.example.com:puppet/app.git')
      expect(mods['stdlib']).to include('kind' => 'forge', 'ref' => '9.7.0', 'version' => '9.7.0', 'source' => 'example-stdlib')
      expect(mods['orphan']).to include('kind' => 'deployed', 'version' => '0.1.0', 'source' => 'https://git.example.com/orphan')
      expect(mods['profile']).to include('kind' => 'control', 'status' => 'ok')
    end

    it 'needs no git, and never writes into the code directory' do
      expect(Dir.glob(File.join(code_dir, '**', 'doc'))).to be_empty
      expect(Dir.exist?(File.join(tmp, 'cache', 'git'))).to be(false)
    end

    it 'rebuilds when the deploy signature changes' do
      prod = live('production')
      write(File.join(code_dir, 'production', '.r10k-deploy.json'), JSON.generate(deploy_info('c' * 40, 'b' * 40)))
      run_app(dir_config)
      expect(live('production')).not_to eq(prod)
      expect(build_json('production')['provenance']['commit']).to eq('c' * 40)
    end

    it 'rebuilds when a module SHA in the deploy file changes' do
      prod = live('production')
      write(File.join(code_dir, 'production', '.r10k-deploy.json'), JSON.generate(deploy_info('a' * 40, 'd' * 40)))
      run_app(dir_config)
      expect(live('production')).not_to eq(prod)
    end

    it 'ignores a redeploy that changed nothing but the timestamps' do
      prod = live('production')
      info = deploy_info('a' * 40, 'b' * 40).merge('finished_at' => '2026-11-02T00:00:00Z')
      write(File.join(code_dir, 'production', '.r10k-deploy.json'), JSON.generate(info))
      run_app(dir_config)
      expect(live('production')).to eq(prod)
    end
  end

  context 'without .r10k-deploy.json' do
    before do
      environment('production')
      environment('feature_x')
      run_app(dir_config)
    end

    it 'builds each directory and falls back to metadata.json' do
      expect(live('production')).not_to be_nil
      expect(live('feature_x')).not_to be_nil
      prov = build_json('production')['provenance']
      expect(prov['change_detection']).to eq('content hash')
      expect(prov).not_to have_key('commit')
      expect(build_json('production')['modules'].find { |m| m['name'] == 'app' }).to include('version' => '2.0.0', 'sha' => nil)
    end

    it 'rebuilds only the environment whose content changed' do
      prod = live('production')
      feat = live('feature_x')
      write(File.join(code_dir, 'feature_x/modules/app/manifests/new.pp'), manifest('app', 'app::new'))
      run_app(dir_config)
      expect(live('production')).to eq(prod)
      expect(live('feature_x')).not_to eq(feat)
    end

    it 'removes an environment whose directory is gone' do
      FileUtils.rm_rf(File.join(code_dir, 'feature_x'))
      expect(run_app(dir_config)).to eq(0)
      expect(live('feature_x')).to be_nil
      expect(builds.grep(/\Afeature_x-/)).to be_empty
    end

    it 'applies the environment filters' do
      run_app(dir_config('exclude_environments' => ['^feature_']))
      expect(live('feature_x')).to be_nil
      expect(live('production')).not_to be_nil
    end
  end

  context 'with a tarball' do
    let(:tarball) { File.join(tmp, 'drop', 'staging.tar.gz') }
    let(:cfg) { config('source' => 'directory', 'tarballs' => { 'staging' => tarball }) }

    def pack(root_name)
      src = File.join(tmp, 'src')
      FileUtils.rm_rf(src)
      environment('staging', root: File.join(src, root_name), deploy: deploy_info('e' * 40, 'b' * 40))
      yield File.join(src, root_name) if block_given?
      FileUtils.mkdir_p(File.dirname(tarball))
      sh('tar', '-czf', tarball, '-C', src, root_name)
    end

    it 'unpacks it, descending into a single top-level directory, and records its checksum' do
      pack('staging')
      expect(run_app(cfg)).to eq(0)
      prov = build_json('staging')['provenance']
      expect(prov).to include('tarball' => 'staging.tar.gz', 'change_detection' => 'tarball checksum', 'commit' => 'e' * 40)
      expect(prov['tarball_sha256']).to eq(Digest::SHA256.file(tarball).hexdigest)
      expect(build_json('staging')['modules'].map { |m| m['name'] }).to contain_exactly('profile', 'stdlib', 'app', 'orphan')
    end

    it 'rebuilds when the tarball changes and not otherwise' do
      pack('staging')
      run_app(cfg)
      first = live('staging')
      run_app(cfg)
      expect(live('staging')).to eq(first)
      pack('staging') { |root| write(File.join(root, 'modules/app/manifests/extra.pp'), manifest('app', 'app::extra')) }
      run_app(cfg)
      expect(live('staging')).not_to eq(first)
      expect(Dir.children(File.join(tmp, 'cache', 'tarballs')).size).to eq(1)
    end

    it 'keeps the last good build when the tarball is unreadable' do
      pack('staging')
      run_app(cfg)
      good = live('staging')
      File.write(tarball, 'not a tarball')
      expect(run_app(cfg)).to eq(1)
      expect(live('staging')).to eq(good)
      expect(status['environments']['staging']['last_attempt']['status']).to eq('failed')
    end

    it 'combines tarballs with code_dir environments' do
      pack('staging')
      environment('production')
      both = config('source' => 'directory', 'code_dir' => code_dir, 'tarballs' => { 'staging' => tarball })
      expect(run_app(both)).to eq(0)
      expect(live('staging')).not_to be_nil
      expect(live('production')).not_to be_nil
    end
  end
end
