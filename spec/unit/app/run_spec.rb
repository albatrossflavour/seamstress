# frozen_string_literal: true

require_relative 'app_helper'

# What a run does when its settings or its source are wrong: which
# environments it takes on, and what it tells the log and the site.
describe 'a seamstress run' do
  include AppHelper

  let(:code_dir) { File.join(tmp, 'environments') }
  let(:index_page) { File.read(File.join(tmp, 'www', 'index.html')) }

  def environment(name)
    write(File.join(code_dir, name, 'modules/app/manifests/init.pp'), manifest('app'))
  end

  def dir_config(extra = {})
    config({ 'source' => 'directory', 'code_dir' => code_dir }.merge(extra))
  end

  describe 'with an allow list that matches no environment' do
    let(:typo) { dir_config('environments' => ['prodution']) }

    before do
      environment('production')
      environment('staging')
      run_app(dir_config)
      state = File.join(tmp, 'state', 'state.json')
      File.write(state, JSON.generate(JSON.parse(File.read(state)).merge('last_success' => '2026-11-01T00:00:00Z')))
    end

    it 'fails the run' do
      expect(run_app(typo)).to eq(1)
    end

    it 'removes nothing from the site' do
      before_builds = builds
      run_app(typo)
      expect(builds).to eq(before_builds)
      expect(live('production')).not_to be_nil
      expect(status['environments'].keys).to contain_exactly('production', 'staging')
    end

    it 'does not record a success' do
      run_app(typo)
      expect(status['last_success']).to eq('2026-11-01T00:00:00Z')
      expect(status['last_attempt']).not_to eq('2026-11-01T00:00:00Z')
    end

    it 'logs an error that names the settings and what the source has' do
      run_app(typo)
      expect(log).to match(/<3>.*environments and exclude_environments settings.*production, staging/)
    end

    it 'does the same when the exclude list is what leaves nothing' do
      expect(run_app(dir_config('exclude_environments' => ['.']))).to eq(1)
      expect(live('staging')).not_to be_nil
    end
  end

  describe 'with an allow-list entry that matches no environment beside ones that do' do
    before do
      environment('production')
      environment('staging')
    end

    it 'warns about the entry and builds the rest' do
      expect(run_app(dir_config('environments' => %w[production stagin]))).to eq(0)
      expect(log).to include('<4>environments names stagin,')
      expect(log).not_to include('<4>environments names production')
      expect(live('production')).not_to be_nil
    end
  end

  describe 'limited to one environment' do
    before do
      environment('production')
      environment('staging')
    end

    it 'builds only that one, and does not record a success for the whole site' do
      expect(run_app(dir_config, only: 'staging')).to eq(0)
      expect(live('staging')).not_to be_nil
      expect(live('production')).to be_nil
      expect(status['last_success']).to be_nil
      expect(status['last_attempt']).not_to be_nil
    end

    it 'says an environment it does not have is unknown, and exits 2' do
      expect(run_app(dir_config, only: 'stagin')).to eq(2)
      expect(log).to match(/<3>unknown environment stagin: .*production, staging/)
      expect(live('production')).to be_nil
    end
  end

  describe 'when an environment fails to build' do
    let(:tarball) { File.join(tmp, 'drop', 'staging.tar.gz') }
    let(:cfg) { config('source' => 'directory', 'tarballs' => { 'staging' => tarball }) }
    let(:attempt) { status['environments']['staging']['last_attempt'] }

    def pack
      src = File.join(tmp, 'src')
      write(File.join(src, 'staging/modules/app/manifests/init.pp'), manifest('app'))
      FileUtils.mkdir_p(File.dirname(tarball))
      sh('tar', '-czf', tarball, '-C', src, 'staging')
    end

    context 'with a tarball that is not one' do
      before do
        write(tarball, 'not a tarball')
        run_app(cfg)
      end

      it 'publishes the stage and one line of reason, without the command or the paths of the server' do
        expect(attempt).to include('status' => 'failed', 'stage' => 'plan')
        expect(attempt['error']).to start_with('tar exited ')
        expect(attempt['error']).not_to include(tmp, '-xf', "\n")
        expect(index_page).to include('failed at the plan stage: tar exited ')
        expect(index_page).not_to include(tmp)
      end

      it 'still logs the whole of it' do
        expect(log).to include("-xf #{tarball}")
      end

      it 'does not say a previous build stays live when there has never been one' do
        expect(log).to include('staging: build failed at the plan stage, there is no earlier build to serve')
        expect(log).not_to include('previous build')
      end
    end

    it 'says the previous build stays live when there is one' do
      pack
      run_app(cfg)
      write(tarball, 'not a tarball')
      run_app(cfg)
      expect(log).to include('staging: build failed at the plan stage, the previous build stays live')
    end

    it 'names the tarballs setting when the tarball is not there' do
      expect(run_app(cfg)).to eq(1)
      expect(attempt['error']).to eq('no readable tarball at staging.tar.gz: check the path the tarballs setting gives for staging')
      expect(log).to include("no readable tarball at #{tarball}")
    end
  end

  describe 'when a module fails to document' do
    before do
      environment('production')
      write(File.join(code_dir, 'production', 'modules/app/FAIL_STRINGS'), '')
      run_app(dir_config)
    end

    it 'publishes what puppet strings said, without the command or the paths of the server' do
      app = build_json('production')['modules'].find { |m| m['name'] == 'app' }
      expect(app).to include('status' => 'failed', 'phase' => 'strings')
      expect(app['error']).to eq('puppet exited 1: Error: could not parse manifests/init.pp')
      expect(log).to include("#{fake_puppet} strings generate")
    end
  end

  # An unmounted code directory, or a deploy caught half way.
  describe 'when the source has no environments, where there were some' do
    before do
      environment('production')
      run_app(dir_config)
      FileUtils.rm_rf(File.join(code_dir, 'production'))
    end

    it 'removes nothing, says so, and fails the run', :aggregate_failures do
      before = status['last_success']
      expect(run_app(dir_config)).to eq(1)
      expect(File).to exist(File.join(tmp, 'www', 'environments', 'production', 'index.html'))
      expect(log).to include('the source has no environments, where there were some: nothing was built and nothing was removed')
      expect(status['last_success']).to eq(before)
    end
  end

  describe 'a cache marker an unpacked tarball brought with it as a link' do
    it 'is replaced, not written through' do
      dir = File.join(tmp, 'cache', 'forge', 'x-1.0.0')
      FileUtils.mkdir_p(dir)
      target = File.join(tmp, 'elsewhere')
      File.symlink(target, File.join(dir, '.seamstress_complete'))
      expect(Seamstress.complete?(dir)).to be(false)
      Seamstress.mark_complete(dir)
      expect(File).not_to exist(target)
      expect(Seamstress.complete?(dir)).to be(true)
    end
  end
end
