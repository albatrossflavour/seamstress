# frozen_string_literal: true

require_relative 'app_helper'

describe 'seamstress in git mode' do
  include AppHelper

  let(:app_repo) { module_repo('app') }
  let(:control) { control_repo("mod 'app', git: '#{app_repo}', branch: 'main'\n") }
  let(:cfg) { config('control_repo' => control) }

  before do
    git(control, 'checkout', '-q', '-b', 'development')
    git(control, 'checkout', '-q', 'production')
  end

  describe 'a first run' do
    let!(:exit_status) { run_app(cfg) }

    it 'succeeds' do
      expect(exit_status).to eq(0)
    end

    it 'builds every branch and points a symlink at each build' do
      expect(live('production')).to match(/\Aproduction-\h{12}\z/)
      expect(live('development')).to match(/\Adevelopment-\h{12}\z/)
      expect(builds.size).to eq(2)
    end

    it 'records each module with its ref, resolved SHA, version, and source' do
      mods = build_json('production')['modules'].to_h { |m| [m['name'], m] }
      expect(mods.keys).to contain_exactly('profile', 'app')
      expect(mods['app']).to include('kind' => 'git', 'ref' => 'main', 'version' => '1.2.3', 'status' => 'ok',
                                     'sha' => git(app_repo, 'rev-parse', 'HEAD').strip)
      expect(mods['profile']).to include('kind' => 'control', 'source' => 'site-modules/profile')
    end

    it 'records the control-repo commit and build time' do
      prov = build_json('production')['provenance']
      expect(prov).to include('source' => 'git', 'branch' => 'production', 'commit' => git(control, 'rev-parse', 'HEAD').strip)
      expect(build_json('production')['built_at']).to match(/\A\d{4}-\d\d-\d\dT/)
    end

    it 'writes an index, a search index, and a page per module and object from the strings JSON' do
      www = File.join(tmp, 'www')
      expect(File.read(File.join(www, 'index.html'))).to include('environments/production/index.html')
      search = JSON.parse(File.read(File.join(www, 'environments', 'production', 'search.json')))
      expect(search).to include(include('n' => 'app', 'k' => 'class', 'm' => 'app', 's' => 'Summary of app.',
                                        'u' => 'modules/app/classes/app.html'))
      expect(search).to include(include('n' => 'app::deploy', 'k' => 'plan', 'u' => 'modules/app/plans/app.deploy.html'))
      expect(search).to include(include('n' => 'app', 'k' => 'module', 'u' => 'modules/app/index.html'))
      page = File.read(File.join(www, 'environments', 'production', 'modules', 'app', 'classes', 'app.html'))
      expect(page).to include('../../../../../assets/site.js', 'data-env="production"', 'data-search-base="../../../"')
      expect(File.read(File.join(www, 'environments', 'production', 'modules', 'app', 'index.html'))).to include('Summary of app.')
      expect(File).to exist(File.join(www, 'environments', 'production', 'modules', 'app', 'strings.json'))
      expect(File).not_to exist(File.join(www, 'environments', 'production', 'modules', 'app', 'class_list.html'))
    end

    it 'writes the comparison page and its data' do
      compare = JSON.parse(File.read(File.join(tmp, 'www', 'compare.json')))
      expect(compare.keys).to contain_exactly('production', 'development')
      expect(compare.dig('production', 'modules', 'app')).to include('kind' => 'git', 'ref' => 'main')
      expect(File.read(File.join(tmp, 'www', 'compare.html'))).to include('0 changed', 'data-compare-left="production"')
    end

    it 'writes the metrics file' do
      expect(metrics).to include('seamstress_failed_modules' => 0, 'seamstress_failed_environments' => 0)
      expect(metrics['seamstress_last_success_timestamp_seconds']).to be > 0
      expect(metrics['seamstress_last_attempt_timestamp_seconds']).to eq(metrics['seamstress_last_success_timestamp_seconds'])
    end
  end

  describe 'change detection' do
    before { run_app(cfg) }

    it 'rebuilds nothing when no SHA moved' do
      before_builds = builds
      Seamstress::Log.io = StringIO.new
      expect(run_app(cfg)).to eq(0)
      expect(builds).to eq(before_builds)
      expect(log).not_to include('building')
    end

    it 'rebuilds only the environment whose control-repo commit moved' do
      dev = live('development')
      prod = live('production')
      write(File.join(control, 'site-modules/profile/manifests/extra.pp'), manifest('profile', 'profile::extra'))
      commit(control, 'change production')
      Seamstress::Log.io = StringIO.new
      expect(run_app(cfg)).to eq(0)
      expect(live('production')).not_to eq(prod)
      expect(live('development')).to eq(dev)
      expect(log).to include('production: building')
      expect(log).not_to include('development: building')
    end

    it 'rebuilds every environment when a branch-tracking module moves' do
      dev = live('development')
      prod = live('production')
      write(File.join(app_repo, 'manifests/more.pp'), manifest('app', 'app::more'))
      sha = commit(app_repo, 'move main')
      expect(run_app(cfg)).to eq(0)
      expect(live('production')).not_to eq(prod)
      expect(live('development')).not_to eq(dev)
      expect(build_json('production')['modules'].find { |m| m['name'] == 'app' }['sha']).to eq(sha)
    end

    it 'records and shows what changed since the build it replaces' do
      old_sha = build_json('production')['modules'].find { |m| m['name'] == 'app' }['sha']
      first_built = build_json('production')['built_at']
      write(File.join(app_repo, 'manifests/more.pp'), manifest('app', 'app::more'))
      sha = commit(app_repo, 'move main')
      run_app(cfg)
      changes = build_json('production')['changes']
      expect(changes).to include('since' => first_built, 'changed' => { 'app' => ['sha'] }, 'added' => [], 'removed' => [])
      expect(changes.dig('previous_modules', 'app', 'sha')).to eq(old_sha)
      page = File.read(File.join(tmp, 'www', 'environments', 'production', 'index.html'))
      expect(page).to include('1 module moved.', old_sha[0, 12], sha[0, 12])
    end

    it 'reuses documentation for modules whose SHA did not move' do
      write(File.join(control, 'README.md'), 'docs')
      commit(control, 'touch only the readme')
      Seamstress::Log.io = StringIO.new
      allow(Seamstress::Command).to receive(:run).and_call_original
      run_app(cfg)
      expect(Seamstress::Command).not_to have_received(:run).with(array_including('strings'), anything)
    end

    it 'rebuilds everything when forced' do
      prod = live('production')
      expect(run_app(cfg, force: true)).to eq(0)
      expect(live('production')).not_to eq(prod)
    end
  end

  describe 'failures' do
    before { run_app(cfg) }

    it 'keeps the last good build live when an environment fails, and says so' do
      good = live('production')
      write(File.join(control, 'Puppetfile'), "mod 'broken',\n")
      bad = commit(control, 'break the Puppetfile')
      expect(run_app(cfg)).to eq(1)
      expect(live('production')).to eq(good)
      attempt = status['environments']['production']['last_attempt']
      expect(attempt).to include('status' => 'failed', 'commit' => bad)
      expect(attempt['error']).to include('cannot parse Puppetfile')
      expect(status['environments']['production']['build']).to eq(good)
      expect(File.read(File.join(tmp, 'www', 'index.html'))).to include('The previous good build is still being served.')
      expect(metrics['seamstress_failed_environments']).to eq(1)
      expect(metrics['seamstress_last_success_timestamp_seconds']).to be < metrics['seamstress_last_attempt_timestamp_seconds'] + 1
      expect(log).to include('production: build failed, the previous build stays live')
    end

    it 'clears the failure once the environment builds again' do
      write(File.join(control, 'Puppetfile'), "mod 'broken',\n")
      commit(control, 'break')
      run_app(cfg)
      write(File.join(control, 'Puppetfile'), '')
      commit(control, 'fix')
      expect(run_app(cfg)).to eq(0)
      expect(status['environments']['production']['last_attempt']['status']).to eq('ok')
      expect(metrics['seamstress_failed_environments']).to eq(0)
    end

    it 'contains a module that fails to document and still publishes the rest' do
      write(File.join(app_repo, 'FAIL_STRINGS'), '')
      commit(app_repo, 'break app')
      expect(run_app(cfg)).to eq(0)
      mods = build_json('production')['modules'].to_h { |m| [m['name'], m] }
      expect(mods['app']).to include('status' => 'failed', 'phase' => 'strings', 'transient' => false)
      expect(mods['app']['error']).to include('could not parse manifests/init.pp')
      expect(mods['profile']['status']).to eq('ok')
      expect(metrics['seamstress_failed_modules']).to eq(2) # app, in both environments
      expect(File.read(File.join(tmp, 'www', 'environments', 'production', 'index.html'))).to include('Docs failed at the strings stage')
    end

    it 'contains a module whose ref cannot be resolved, and retries it next run' do
      write(File.join(control, 'Puppetfile'), "mod 'app', git: '#{app_repo}', branch: 'nope'\n")
      commit(control, 'bad ref')
      expect(run_app(cfg)).to eq(0)
      app = build_json('production')['modules'].find { |m| m['name'] == 'app' }
      expect(app).to include('status' => 'failed', 'phase' => 'resolve', 'transient' => true)
      prod = live('production')
      run_app(cfg)
      expect(live('production')).not_to eq(prod)
    end

    it 'fails the run without touching the site when the control repo is unreachable' do
      before_builds = builds
      bad = config('control_repo' => File.join(tmp, 'missing'))
      expect(run_app(bad)).to eq(1)
      expect(builds).to eq(before_builds)
      expect(live('production')).not_to be_nil
      expect(log).to include('cannot list environments')
    end
  end

  describe 'pruning' do
    it 'keeps the live build plus one previous by default' do
      run_app(cfg)
      3.times do |i|
        write(File.join(control, "site-modules/profile/manifests/c#{i}.pp"), manifest('profile', "profile::c#{i}"))
        commit(control, "change #{i}")
        run_app(cfg)
      end
      prod = builds.grep(/\Aproduction-/)
      expect(prod.size).to eq(2)
      expect(prod).to include(live('production'))
    end

    it 'honours keep_builds' do
      one = config('control_repo' => control, 'keep_builds' => 1)
      run_app(one)
      write(File.join(control, 'site-modules/profile/manifests/x.pp'), manifest('profile', 'profile::x'))
      commit(control, 'change')
      run_app(one)
      expect(builds.grep(/\Aproduction-/)).to eq([live('production')])
    end

    it 'removes an environment whose branch was deleted' do
      run_app(cfg)
      git(control, 'branch', '-q', '-D', 'development')
      expect(run_app(cfg)).to eq(0)
      expect(live('development')).to be_nil
      expect(builds.grep(/\Adevelopment-/)).to be_empty
      expect(status['environments']).not_to have_key('development')
    end

    it 'removes an environment newly excluded by the filters' do
      run_app(cfg)
      run_app(config('control_repo' => control, 'exclude_environments' => ['^dev']))
      expect(live('development')).to be_nil
      expect(live('production')).not_to be_nil
    end

    it 'drops documentation cache entries no build uses' do
      run_app(cfg)
      write(File.join(control, 'site-modules/profile/manifests/x.pp'), manifest('profile', 'profile::x'))
      commit(control, 'change')
      run_app(config('control_repo' => control, 'keep_builds' => 1))
      git(control, 'branch', '-q', '-D', 'development')
      run_app(config('control_repo' => control, 'keep_builds' => 1))
      used = Dir.glob(File.join(tmp, 'www', 'builds', '*', 'build.json'))
                .flat_map { |f| JSON.parse(File.read(f))['modules'].map { |m| m['cache_key'] } }.uniq
      expect(Dir.children(File.join(tmp, 'cache', 'docs')).size).to eq(used.size)
    end
  end
end
