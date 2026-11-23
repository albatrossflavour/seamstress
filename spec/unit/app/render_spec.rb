# frozen_string_literal: true

require_relative 'app_helper'

# Renders one environment straight from puppet-strings JSON, with no build
# around it, and checks the pages that come out.
describe Seamstress::Renderer do
  include AppHelper

  let(:fixtures) { File.join(__dir__, 'fixtures') }
  let(:renderer) { described_class.new(config('control_repo' => 'x', 'site_title' => 'Docs <&> site')) }
  let(:dir) { File.join(tmp, 'build') }
  let(:profile_json) do
    { 'puppet_classes' => [{ 'name' => 'profile::base', 'file' => 'manifests/base.pp', 'line' => 3,
                             'docstring' => { 'text' => '', 'tags' => [] }, 'source' => 'class profile::base {}' }] }
  end
  let(:stdlib_json) do
    { 'data_type_aliases' => [{ 'name' => 'Stdlib::Absolutepath', 'file' => 'types/absolutepath.pp', 'line' => 2,
                                'docstring' => { 'text' => '', 'tags' => [{ 'tag_name' => 'summary', 'text' => 'An absolute path.' }] },
                                'alias_of' => 'Variant[Stdlib::Unixpath, Stdlib::Windowspath]' }] }
  end
  let(:manifest) do
    {
      'environment' => 'production', 'built_at' => '2026-11-22T10:00:00Z',
      'provenance' => { 'source' => 'git', 'commit' => 'a' * 40 }, 'generator' => { 'puppet_strings' => '5.1.0' },
      'modules' => [
        { 'name' => 'webapp', 'kind' => 'control', 'source' => 'site-modules/webapp', 'ref' => 'abc', 'sha' => 'b' * 40,
          'version' => '0.3.0', 'status' => 'ok', 'index' => 'index.html' },
        { 'name' => 'profile', 'kind' => 'control', 'source' => 'site-modules/profile', 'status' => 'ok', 'index' => 'index.html' },
        { 'name' => 'stdlib', 'kind' => 'forge', 'source' => 'puppetlabs-stdlib', 'version' => '9.7.0', 'sha' => 'c' * 64,
          'status' => 'ok', 'index' => 'index.html' }
      ]
    }
  end

  def page(*path)
    File.read(File.join(dir, *path))
  end

  def mod_dir(name)
    File.join(dir, 'modules', name).tap { |d| FileUtils.mkdir_p(d) }
  end

  def search
    JSON.parse(page('search.json'))
  end

  before do
    FileUtils.cp(File.join(fixtures, 'webapp_strings.json'), File.join(mod_dir('webapp'), 'strings.json'))
    FileUtils.cp(File.join(fixtures, 'webapp_metadata.json'), File.join(mod_dir('webapp'), 'metadata.json'))
    FileUtils.cp(File.join(fixtures, 'webapp_README.markdown'), File.join(mod_dir('webapp'), 'README.md'))
    File.write(File.join(mod_dir('profile'), 'strings.json'), JSON.generate(profile_json))
    File.write(File.join(mod_dir('stdlib'), 'strings.json'), JSON.generate(stdlib_json))
    renderer.environment(dir, manifest)
  end

  describe 'object pages' do
    it 'writes one page per object of every kind, under a directory per kind' do
      %w[classes/webapp.html classes/webapp.config.html defined_types/webapp.vhost.html types/webapp_site.html
         providers/webapp_site-cli.html functions/webapp.slug.html functions/webapp.url.html tasks/webapp.restart.html
         plans/webapp.rollout.html type_aliases/Webapp.Port.html data_types/Webapp.Endpoint.html index.html].each do |f|
        expect(File).to exist(File.join(dir, 'modules', 'webapp', f)), f
      end
    end

    it 'shows the summary, the file and line, and the identifier as the headline' do
      html = page('modules/webapp/defined_types/webapp.vhost.html')
      expect(html).to include('<span class="ns">webapp::</span><span class="leaf">vhost</span>')
      expect(html).to include('A virtual host served by the web application.')
      expect(html).to include('In <code>manifests/vhost.pp</code>, line 12')
    end

    it 'tabulates parameters with types, defaults, descriptions, and required ones marked' do
      html = page('modules/webapp/defined_types/webapp.vhost.html')
      docroot = html[%r{<tr id="p-docroot">.*?</tr>}m]
      expect(docroot).to include('tag-required', 'none', 'Where the site&#39;s files live.')
      name = html[%r{<tr id="p-server_name">.*?</tr>}m]
      expect(name).to include('<code>$title</code>').and include('String[1]')
      expect(name).not_to include('tag-required')
    end

    it 'gives every section and parameter an anchor that links to itself' do
      html = page('modules/webapp/classes/webapp.html')
      %w[parameters examples relations source p-port p-log_dir].each do |id|
        expect(html).to include(%(id="#{id}")).and include(%(href="##{id}"))
      end
      expect(html).to include('<a href="#p-port"><code>port</code></a>') # on this page
    end

    it 'marks an undocumented parameter as such' do
      expect(page('modules/webapp/classes/webapp.html')[%r{<tr id="p-log_dir">.*?</tr>}m]).to include('Not documented.')
    end

    it 'shows options under the parameter they belong to' do
      sites = page('modules/webapp/classes/webapp.html')[%r{<tr id="p-sites">.*?</tr>}m]
      expect(sites).to include('<code>docroot</code>', 'Per-site docroot.')
    end

    it 'highlights examples and source as Puppet, Ruby, or JSON' do
      expect(page('modules/webapp/classes/webapp.html')).to include('<span class="hl-kw">class</span>', 'data-lang="puppet"')
      expect(page('modules/webapp/functions/webapp.slug.html')).to include('data-lang="ruby"')
      expect(page('modules/webapp/tasks/webapp.restart.html')).to include('data-lang="json"', 'hl-key')
      expect(page('modules/webapp/plans/webapp.rollout.html')).to include('data-lang="shell"') # a bolt command line
    end

    it 'renders each function signature with its own parameters and return type' do
      html = page('modules/webapp/functions/webapp.slug.html')
      expect(html.scan('class="signature"').size).to eq(2)
      expect(html).to include('id="sig-1-p-text"', 'id="sig-2-p-text"', 'Array[String]', 'One slug each.')
    end

    it 'shows a resource type with its properties, parameters, namevar, and providers' do
      html = page('modules/webapp/types/webapp_site.html')
      expect(html).to include('id="properties"', 'id="parameters"', 'tag-namevar', 'present, absent')
      expect(html).to include('href="../../../modules/webapp/providers/webapp_site-cli.html"')
      provider = page('modules/webapp/providers/webapp_site-cli.html')
      expect(provider).to include('osfamily = redhat', 'webappctl', 'href="../../../modules/webapp/types/webapp_site.html"')
    end

    it 'shows tasks with no-op support and their parameters, required unless Optional' do
      html = page('modules/webapp/tasks/webapp.restart.html')
      expect(html).to include('No-op mode', 'Supported')
      expect(html[%r{<tr id="p-drain">.*?</tr>}m]).to include('tag-required')
      expect(html[%r{<tr id="p-timeout">.*?</tr>}m]).not_to include('tag-required')
    end

    it 'shows a type alias with what it is an alias of, and a data type' do
      expect(page('modules/webapp/type_aliases/Webapp.Port.html')).to include('Alias of', 'Integer[1024, 65535]')
      expect(page('modules/webapp/data_types/Webapp.Endpoint.html')).to include('An endpoint the application talks to.')
    end

    it 'flags private and deprecated objects' do
      html = page('modules/webapp/classes/webapp.config.html')
      expect(html).to include('tag-private', 'tag-deprecated', 'Use <a class="xref"')
    end

    it 'puts the object in a breadcrumb trail and the sidebar, marked current' do
      html = page('modules/webapp/classes/webapp.html')
      expect(html).to include('<nav class="crumbs"', '<a href="../../../index.html">production</a>')
      expect(html).to include('<li><a href="../../../modules/webapp/classes/webapp.html" aria-current="page">webapp</a></li>')
      expect(html).to include('data-tree-mod="stdlib"')
    end
  end

  describe 'cross-links' do
    let(:html) { page('modules/webapp/classes/webapp.html') }

    it "links a parameter's type to its type alias, in this module or another" do
      expect(html).to include('<a class="xref" href="../../../modules/webapp/type_aliases/Webapp.Port.html">Webapp::Port</a>')
      expect(html).to include('<a class="xref" href="../../../modules/stdlib/type_aliases/Stdlib.Absolutepath.html">Stdlib::Absolutepath</a>')
    end

    it 'links inline code that names an object' do
      expect(html).to include('<a class="xref" href="../../../modules/profile/classes/profile.base.html"><code>profile::base</code></a>')
    end

    it 'lists what an object uses and what uses it' do
      relations = html[%r{<section id="relations".*?</section>}m]
      expect(relations).to include('modules/profile/classes/profile.base.html', 'modules/webapp/classes/webapp.config.html',
                                   'modules/webapp/defined_types/webapp.vhost.html')
      expect(relations).not_to include('modules/webapp/classes/webapp.html"')
      used_by = page('modules/webapp/defined_types/webapp.vhost.html')[%r{<section id="relations".*?</section>}m]
      expect(used_by).to include('Used by', 'modules/webapp/classes/webapp.html')
    end

    it 'links module dependencies to the module page when present and to the Forge when not' do
      deps = page('modules/webapp/index.html')[%r{<section id="dependencies".*?</section>}m]
      expect(deps).to include('href="../../modules/stdlib/index.html">puppetlabs-stdlib</a>')
      expect(deps).to include('href="https://forge.puppet.com/modules/puppetlabs/concat"', 'tag-missing')
    end
  end

  describe 'untrusted content' do
    let(:all_html) { Dir.glob(File.join(dir, '**', '*.html')).map { |f| File.read(f) }.join("\n") }

    it 'never lets a script, an event handler, or a javascript: link through' do
      expect(all_html).not_to match(%r{<script(?![^>]*\bsrc="[./]*assets/site\.js")}i)
      expect(all_html).not_to match(/\son(error|click|mouseover)=/i)
      expect(all_html).not_to match(/href="\s*javascript:/i)
      expect(all_html).not_to include('<img')
    end

    it 'keeps the text of what it removes or escapes, and safe links' do
      html = page('modules/webapp/classes/webapp.html')
      expect(html).to include('<a href="https://example.com/a?b=1&amp;c=2" rel="noopener noreferrer">good</a>')
      expect(page('modules/webapp/data_types/Webapp.Endpoint.html')).to include('A network endpoint bold.')
      expect(page('modules/webapp/functions/webapp.url.html')).to include('Builds the URL .')
    end

    it 'escapes the site title' do
      expect(page('index.html')).to include('Docs &lt;&amp;&gt; site')
    end

    it 'renders the README without its script, image, or comment' do
      readme = page('modules/webapp/index.html')[%r{<section id="readme".*?</section>}m]
      expect(readme).to include('<strong>systemd</strong>', '<table>', '<blockquote>', 'id="readme-usage"')
      expect(readme).not_to include('readme xss', 'tracker.example.com', 'hidden comment')
    end

    it 'does not leave the module files it only read in the published build' do
      expect(File).not_to exist(File.join(dir, 'modules', 'webapp', 'README.md'))
      expect(File).not_to exist(File.join(dir, 'modules', 'webapp', 'metadata.json'))
      expect(File).to exist(File.join(dir, 'modules', 'webapp', 'strings.json'))
    end
  end

  describe 'the module page' do
    let(:html) { page('modules/webapp/index.html') }

    it 'shows version, source, ref, resolved SHA, licence, and supported platforms' do
      expect(html).to include('0.3.0', 'site-modules/webapp', '<code>abc</code>', 'b' * 12, 'Apache-2.0', 'Ubuntu', '22.04, 24.04')
    end

    it 'lists the contents by kind and links the raw puppet-strings JSON' do
      expect(html).to include('id="classes"', 'id="type_aliases"', 'href="strings.json"')
    end
  end

  describe 'the environment dashboard and its data' do
    it 'records counts and coverage per module and for the environment' do
      built = JSON.parse(page('build.json'))
      webapp = built['modules'].find { |m| m['name'] == 'webapp' }
      expect(webapp['counts']).to include('class' => 2, 'function' => 2, 'provider' => 1, 'data type' => 1)
      expect(webapp['coverage']).to include('documented' => be < webapp['coverage']['total'])
      profile = built['modules'].find { |m| m['name'] == 'profile' }
      expect(profile['coverage']).to eq('documented' => 0, 'total' => 1, 'percent' => 0)
      expect(built['coverage']['total']).to eq(%w[webapp profile stdlib].sum { |n|
        built['modules'].find { |m|
          m['name'] == n
        }['coverage']['total']
      })
    end

    it 'lists modules with documentation gaps, least documented first, naming what is missing' do
      gaps = page('index.html')[%r{<section id="gaps".*?</section>}m]
      expect(gaps.index('profile')).to be < gaps.index('webapp')
      expect(gaps).to include('<code>$log_dir</code>', 'a summary')
      expect(gaps).not_to include('>stdlib<')
    end

    it 'says when there is no earlier build to compare with' do
      expect(page('index.html')).to include('first build of production')
    end

    it 'counts modules by source' do
      expect(page('index.html')).to include('<span class="kind kind-control">control</span> 2',
                                            '<span class="kind kind-forge">forge</span> 1')
    end
  end

  describe 'the search index' do
    it 'has an entry for every module, object, and parameter, each with a link' do
      kinds = search.group_by { |e| e['k'] }.transform_values(&:size)
      expect(kinds).to include('module' => 3, 'class' => 3, 'defined type' => 1, 'resource type' => 1, 'provider' => 1,
                               'function' => 2, 'task' => 1, 'plan' => 1, 'type alias' => 2, 'data type' => 1)
      expect(search).to all(include('n', 'k', 'm', 'u'))
    end

    it 'points parameters at their anchor on the owning page' do
      expect(search).to include('n' => 'docroot', 'k' => 'parameter', 'm' => 'webapp', 'p' => 'webapp::vhost',
                                's' => "Where the site's files live.", 'u' => 'modules/webapp/defined_types/webapp.vhost.html#p-docroot')
    end

    it 'names tasks by module and providers by type' do
      expect(search).to include(include('n' => 'webapp::restart', 'u' => 'modules/webapp/tasks/webapp.restart.html'))
      expect(search).to include(include('n' => 'webapp_site/cli', 'k' => 'provider'))
    end

    it 'flattens markdown in summaries' do
      expect(search.find { |e| e['n'] == 'webapp::config' && e['k'] == 'class' }['s']).to eq('Writes the application configuration.')
    end
  end

  describe 'a module that cannot be rendered' do
    before do
      File.write(File.join(mod_dir('broken'), 'strings.json'), JSON.generate('puppet_classes' => [42]))
      manifest['modules'] << { 'name' => 'broken', 'kind' => 'forge', 'source' => 'x-broken', 'status' => 'ok', 'index' => 'index.html' }
      FileUtils.rm_rf(Dir.glob(File.join(dir, '*.html')))
      renderer.environment(dir, manifest)
    end

    it 'is marked failed at the render stage while the rest of the environment publishes' do
      broken = JSON.parse(page('build.json'))['modules'].find { |m| m['name'] == 'broken' }
      expect(broken).to include('status' => 'failed', 'phase' => 'render')
      expect(broken).not_to have_key('index')
      expect(page('index.html')).to include('Docs failed at the render stage')
      expect(search.map { |e| e['m'] }).not_to include('broken')
      expect(File).to exist(File.join(dir, 'modules', 'webapp', 'index.html'))
    end
  end

  describe 'what changed since the previous build' do
    let(:previous) do
      JSON.parse(JSON.generate(manifest)).tap do |m|
        m['built_at'] = '2026-11-21T10:00:00Z'
        m['provenance']['commit'] = 'd' * 40
        m['modules'].find { |x| x['name'] == 'stdlib' }.merge!('version' => '9.6.0', 'sha' => 'e' * 64)
        m['modules'].reject! { |x| x['name'] == 'profile' }
        m['modules'] << { 'name' => 'concat', 'kind' => 'forge', 'version' => '7.0.0', 'status' => 'ok' }
      end
    end

    before { renderer.environment(dir, manifest, previous) }

    it 'records modules added, removed, and changed, with what moved' do
      changes = JSON.parse(page('build.json'))['changes']
      expect(changes).to include('since' => '2026-11-21T10:00:00Z', 'from_commit' => 'd' * 40, 'to_commit' => 'a' * 40,
                                 'added' => ['profile'], 'removed' => ['concat'], 'changed' => { 'stdlib' => %w[version sha] })
      expect(changes['previous_modules'].keys).to contain_exactly('stdlib', 'concat')
    end

    it 'shows them on the dashboard' do
      html = page('index.html')[%r{<section id="changes".*?</section>}m]
      expect(html).to include('3 modules moved.', '9.6.0 to 9.7.0', 'change-added', 'change-removed', 'e' * 12, 'd' * 12)
    end
  end
end
