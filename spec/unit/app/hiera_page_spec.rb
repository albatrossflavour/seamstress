# frozen_string_literal: true

require_relative 'app_helper'

# The Hiera page, end to end: the build writes the index and the page for an
# environment that has a hierarchy, when asked to.
describe 'the Hiera page' do
  include AppHelper

  let(:code_dir) { File.join(tmp, 'environments') }
  let(:live) { File.join(tmp, 'www', 'environments', 'production') }
  let(:samples) { { 'A web server' => { 'trusted.extensions.pp_role' => 'role::web' } } }

  def hierarchy(root)
    write(File.join(root, 'hiera.yaml'), <<~YAML)
      ---
      version: 5
      defaults:
        datadir: data
        data_hash: yaml_data
      hierarchy:
        - name: Roles then everything
          paths:
            - "role/%{trusted.extensions.pp_role}.yaml"
            - "common.yaml"
    YAML
    write(File.join(root, 'data/common.yaml'), "---\nprofile::port: 80\nprofile::token: ENC[PKCS7,MIIBciphertext]\n")
    write(File.join(root, 'data/role/role::web.yaml'), "---\nprofile::port: 443\n")
  end

  def environment
    root = File.join(code_dir, 'production')
    write(File.join(root, 'site-modules/profile/manifests/init.pp'), manifest('profile'))
    hierarchy(root)
    root
  end

  def dir_config(extra = {})
    config({ 'source' => 'directory', 'code_dir' => code_dir }.merge(extra))
  end

  context 'when it is off' do
    before do
      environment
      run_app(dir_config)
    end

    it 'writes no index, no page, and no link' do
      expect(File).not_to exist(File.join(live, 'hiera.json'))
      expect(File).not_to exist(File.join(live, 'hiera.html'))
      expect(build_json('production')).not_to have_key('hiera')
      expect(File.read(File.join(live, 'index.html'))).not_to include('hiera.html')
      expect(File.read(File.join(tmp, 'www', 'index.html'))).not_to include('hiera.html', 'Hiera Explorer', 'and data')
      expect(File.read(File.join(live, 'index.html'))).not_to include('hiera.html', 'Hiera Explorer')
      expect(JSON.parse(File.read(File.join(live, 'search.json'))).map { |e| e['n'] }).not_to include('Hiera Explorer')
    end
  end

  context 'when it is on, from a directory' do
    let!(:exit_status) do
      environment
      run_app(dir_config('hiera' => true, 'hiera_samples' => samples))
    end
    let(:index) { JSON.parse(File.read(File.join(live, 'hiera.json'))) }

    it 'writes the index beside the pages, without the ciphertext' do
      expect(exit_status).to eq(0)
      expect(index['levels'].map { |l| l['path'] }).to eq(['role/%{trusted.extensions.pp_role}.yaml', 'common.yaml'])
      expect(index['data']['data/common.yaml']).to eq('profile::port' => 80, 'profile::token' => { '__enc' => true })
      expect(index['samples']).to eq(samples)
      expect(File.read(File.join(live, 'hiera.json'))).not_to include('MIIBciphertext')
    end

    it 'records it in the manifest' do
      expect(build_json('production')['hiera']).to eq('levels' => 2, 'files' => 2, 'keys' => 2)
    end

    it 'writes the page, with its script, and offers it from the dashboard' do
      page = File.read(File.join(live, 'hiera.html'))
      expect(page).to include('data-hiera-src="hiera.json"', 'assets/hiera.js', '<title>Hiera Explorer | production')
      expect(page).to include('each of the 2 levels', '2 keys in 2 data files.')
      expect(page).not_to include('MIIBciphertext')
      dashboard = File.read(File.join(live, 'index.html'))
      expect(dashboard).to include('<a class="hiera-door" href="hiera.html">', 'which of its 2 levels. 2 keys in 2 data files.')
      expect(dashboard).to include('<span class="hiera-door-title">Hiera Explorer</span>')
      expect(dashboard).not_to include('assets/hiera.js')
      expect(File).to exist(File.join(tmp, 'www', 'assets', 'hiera.js'))
    end

    it 'switches between the two sections in the top bar' do
      page = File.read(File.join(live, 'hiera.html'))
      expect(page).to include('<a href="index.html" data-env-path="index.html">Module documentation</a>',
                              '<a href="hiera.html" data-env-path="hiera.html" data-env-hiera aria-current="true">Hiera Explorer</a>')
      dashboard = File.read(File.join(live, 'index.html'))
      expect(dashboard).to include('<a href="index.html" data-env-path="index.html" aria-current="true">Module documentation</a>',
                                   '<a href="hiera.html" data-env-path="hiera.html" data-env-hiera>Hiera Explorer</a>')
    end

    # A section of its own: none of the module documentation's furniture.
    it 'gives the explorer the full width, with no module tree, class search, or compare link' do
      page = File.read(File.join(live, 'hiera.html'))
      expect(page).to include('<div class="frame frame-site">', '<div class="site-page hiera"')
      expect(page).not_to include('id="sidebar"', 'data-menu-toggle', 'class="search-trigger"', 'compare.html', 'data-search-env')
      dashboard = File.read(File.join(live, 'index.html'))
      expect(dashboard).to include('id="sidebar"', 'class="search-trigger"', 'compare.html')
      expect(dashboard).not_to include('<li><a href="hiera.html">')
    end

    # The base page is about seamstress, with the same bar as every other
    # page: the first environment chosen, and both sections a click away.
    it 'offers both sections from the base page, for the first environment' do
      front = File.read(File.join(tmp, 'www', 'index.html'))
      expect(front).to include('<h1 class="site-title">seamstress</h1>', 'Documentation for your Puppet code and data')
      pill = '<a class="env-pill" href="environments/production/index.html" title="Environment" data-env-choice>production</a>'
      expect(front).to include('data-hiera-envs="production"', pill)
      expect(front).to include('<a href="environments/production/index.html" data-env-path="index.html">Module documentation</a>',
                               '<a href="environments/production/hiera.html" data-env-path="hiera.html" data-env-hiera>Hiera Explorer</a>')
      expect(front).to include('<strong>Module documentation</strong> is the reference', '<strong>Hiera Explorer</strong> shows')
      expect(front).not_to include('class="search-trigger"', 'search-hero', 'class="feature"', 'env-list', 'notice-failed')
    end

    it 'puts it in the search index' do
      search = JSON.parse(File.read(File.join(live, 'search.json')))
      expect(search.first).to include('n' => 'Hiera Explorer', 'k' => 'environment', 'u' => 'hiera.html')
    end

    it 'links it from pages below the environment root' do
      page = File.read(File.join(live, 'modules/profile/index.html'))
      expect(page).to include('<a href="../../index.html" data-env-path="index.html" aria-current="true">Module documentation</a>',
                              '<a href="../../hiera.html" data-env-path="hiera.html" data-env-hiera>Hiera Explorer</a>')
    end

    it 'rebuilds when the data changes, and not otherwise' do
      first = File.readlink(live)
      run_app(dir_config('hiera' => true, 'hiera_samples' => samples))
      expect(File.readlink(live)).to eq(first)
      write(File.join(code_dir, 'production/data/role/role::web.yaml'), "---\nprofile::port: 8443\n")
      run_app(dir_config('hiera' => true, 'hiera_samples' => samples))
      expect(File.readlink(live)).not_to eq(first)
      expect(JSON.parse(File.read(File.join(live, 'hiera.json')))['data']['data/role/role::web.yaml']).to eq('profile::port' => 8443)
    end
  end

  context 'when it is on but the environment has no hierarchy' do
    before do
      write(File.join(code_dir, 'production/site-modules/profile/manifests/init.pp'), manifest('profile'))
      run_app(dir_config('hiera' => true))
    end

    it 'builds the environment without the page' do
      expect(File).to exist(File.join(live, 'index.html'))
      expect(File).not_to exist(File.join(live, 'hiera.html'))
      expect(build_json('production')).not_to have_key('hiera')
    end
  end

  context 'when the hierarchy cannot be read' do
    before do
      environment
      write(File.join(code_dir, 'production/hiera.yaml'), "---\nversion: 5\nhierarchy: [unclosed\n")
      run_app(dir_config('hiera' => true))
    end

    it 'leaves the page out, says so, and still publishes the environment' do
      expect(File).to exist(File.join(live, 'index.html'))
      expect(File).not_to exist(File.join(live, 'hiera.html'))
      expect(log).to include('production: the Hiera page is left out')
    end
  end

  context 'when it is on, from git' do
    before do
      repo = control_repo
      hierarchy(repo)
      commit(repo, 'hiera')
      run_app(config('control_repo' => repo, 'hiera' => true))
    end

    it 'reads the hierarchy and data out of the commit' do
      index = JSON.parse(File.read(File.join(live, 'hiera.json')))
      expect(index['levels'][0]['files']).to eq(
        [{ 'file' => 'data/role/role::web.yaml', 'vars' => { 'trusted.extensions.pp_role' => 'role::web' }, 'keys' => 1 }]
      )
      expect(index['data']['data/common.yaml']['profile::token']).to eq('__enc' => true)
      expect(File).to exist(File.join(live, 'hiera.html'))
      expect(Dir.glob(File.join(tmp, '**', '*.hiera'))).to be_empty
    end
  end
end
