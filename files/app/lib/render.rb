# frozen_string_literal: true

require 'erb'
require 'fileutils'
require 'json'
require 'time'
require_relative 'docs'
require_relative 'highlight'
require_relative 'markdown'

module Seamstress
  # Writes the site: the index of environments, the comparison page, and
  # for each environment its dashboard, a page per module, a page per
  # documented object, and the search index. Every page is drawn from the
  # same templates, so the whole site shares one design.
  class Renderer
    # Kept for search entries' kind labels and the module counts.
    KINDS = Docs::KINDS.to_h { |k| [k.key, k.label] }.freeze

    def initialize(config)
      @config = config
      @templates = {}
    end

    attr_reader :config

    # Renders one environment's build directory in place. previous is the
    # manifest of the build this one replaces, when there is one.
    def environment(dir, manifest, previous = nil)
      env = load_environment(dir, manifest)
      annotate(manifest, env, previous)
      env.modules.each { |mod| module_pages(dir, mod, manifest: manifest, env: env) }
      File.write(File.join(dir, 'search.json'), JSON.generate(search_entries(manifest, env)))
      File.write(File.join(dir, 'build.json'), JSON.pretty_generate(manifest))
      File.write(File.join(dir, 'index.html'),
                 layout('environment', depth: 0, title: manifest['environment'], manifest: manifest, env: env))
      return unless manifest['hiera']

      File.write(File.join(dir, 'hiera.html'), layout('hiera', depth: 0, title: 'Hiera Explorer', manifest: manifest, env: env))
    end

    # The Hiera page is in the search index too, so the palette finds it.
    def search_entries(manifest, env)
      return env.search_entries unless manifest['hiera']

      page = { 'n' => 'Hiera Explorer', 'k' => 'environment', 'm' => manifest['environment'], 'u' => 'hiera.html',
               's' => 'The hierarchy level by level, and what a sample node gets from each' }
      [page] + env.search_entries
    end

    # One module's pages. A module whose documentation cannot be drawn is
    # marked failed and the rest of the environment carries on.
    def module_pages(dir, mod, **ctx)
      mdir = File.join(dir, 'modules', mod.name)
      mod.objects.each do |obj|
        path = File.join(mdir, obj.kind.dir, obj.file_name)
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, layout('object', depth: 3, mod: mod, obj: obj, title: obj.name, **ctx))
      end
      File.write(File.join(mdir, 'index.html'), layout('module', depth: 2, mod: mod, title: mod.name, **ctx))
      %w[metadata.json README.md README.txt].each { |f| FileUtils.rm_f(File.join(mdir, f)) }
    rescue StandardError => e
      fail_module(mod.entry, mdir, e)
    end

    # The site index and the comparison page, from every live build.
    def index(status)
      envs = Environments.sort(status['environments'].keys).map { |n| [n, status['environments'][n]] }
      builds = live_manifests(envs)
      compare = builds.transform_values do |m|
        { 'commit' => m.dig('provenance', 'commit'), 'built_at' => m['built_at'], 'modules' => Docs.module_map(m) }
      end
      docroot = @config['docroot']
      Seamstress.atomic_write(File.join(docroot, 'compare.json'), JSON.generate(compare))
      hiera = builds.transform_values { |m| m['hiera'] }.compact
      ctx = { status: status, envs: envs, compare: compare, hiera: hiera, search_env: builds.keys.first }
      Seamstress.atomic_write(File.join(docroot, 'index.html'), layout('index', site: true, title: nil, **ctx))
      Seamstress.atomic_write(File.join(docroot, 'compare.html'), layout('compare', site: true, title: 'Compare environments', **ctx))
    end

    def page(name, **locals)
      template(name).result_with_hash(locals.merge(config: @config, h: self))
    end

    # A full page: head, top bar, sidebar, and the named template as the
    # main content. depth is how far below the environment root the page
    # sits; site pages sit at the docroot.
    def layout(name, depth: 0, site: false, **locals)
      env_root = '../' * depth
      root = site ? '' : "#{env_root}../../"
      locals = locals.merge(depth: depth, root: root, env_root: env_root, site: site)
      locals[:mod] ||= nil
      locals[:obj] ||= nil
      page('layout', content: page(name, **locals), name: name, **locals)
    end

    # Helpers for the templates.

    def esc(text) = ERB::Util.html_escape(text.to_s)
    def short(sha) = sha.to_s[0, 12]

    def time(iso)
      return '' if iso.to_s.empty?

      Time.parse(iso.to_s).utc.strftime('%Y-%m-%d %H:%M UTC')
    rescue ArgumentError
      iso.to_s
    end

    # Six hex digits of a SHA as a colour, so identical commits show as
    # identical swatches across environments.
    def swatch(sha)
      hex = sha.to_s[/\A\h{6}/]
      hex ? "##{hex}" : nil
    end

    def sha_html(sha)
      return '' if sha.to_s.empty?

      sw = swatch(sha)
      dot = sw ? %(<i class="swatch" style="--swatch: #{sw}" aria-hidden="true"></i>) : ''
      %(<span class="sha">#{dot}<code title="#{esc(sha)}">#{esc(short(sha))}</code></span>)
    end

    # A ref pinned to a full commit is as long as a SHA, so it is drawn as one.
    def ref_html(ref)
      return '' if ref.to_s.empty?

      ref.to_s.match?(/\A\h{40}\z/) ? sha_html(ref) : "<code>#{esc(ref)}</code>"
    end

    def source_link(mod)
      case mod['kind']
      when 'forge'
        slug = mod['source'].to_s
        %(<a href="https://forge.puppet.com/modules/#{esc(slug.tr('-', '/'))}">#{esc(slug)}</a>)
      when 'git'
        web = web_url(mod['source'].to_s)
        web ? %(<a href="#{esc(web)}">#{esc(mod['source'])}</a>) : esc(mod['source'])
      else esc(mod['source'])
      end
    end

    def web_url(url)
      return nil if url.include?('***@')

      case url
      when %r{\Ahttps://[^/]+/.+} then url.delete_suffix('.git')
      when %r{\A(?:ssh://)?git@([^:/]+)[:/](.+?)(?:\.git)?\z} then "https://#{Regexp.last_match(1)}/#{Regexp.last_match(2)}"
      end
    end

    # Markdown from a module, rendered safely, with inline code that names
    # a known object linked to it.
    def md(text, env, depth, prefix: 'md-', lang: 'puppet', offset: 2)
      Markdown.new(linker: linker(env, depth), heading_prefix: prefix, default_lang: lang, heading_offset: offset).render(text)
    end

    def md_inline(text, env, depth)
      Markdown.new(linker: linker(env, depth)).inline(text)
    end

    def code(text, lang)
      language = Highlight.language(lang)
      %(<pre class="code"#{%( data-lang="#{language}") if language}><code>#{Highlight.html(text.to_s, lang)}</code></pre>)
    end

    # Example code is Puppet unless it reads like a command line.
    def example_lang(text, obj)
      return 'shell' if text.match?(/\A\s*(?:\$ |bolt |puppet |sudo )/)
      return 'json' if obj.kind.key == 'puppet_tasks' && text.lstrip.start_with?('{')

      'puppet'
    end

    # A Puppet type expression with each known type alias linked.
    def type_html(types, env, depth)
      esc(types).gsub(/\b[A-Z]\w*(?:::[A-Z]\w*)+/) do |name|
        target = env.type_named(name)
        target ? %(<a class="xref" href="#{'../' * depth}#{target.url}">#{name}</a>) : name
      end
    end

    # An identifier as a headline: the namespace muted, the last segment
    # carrying the weight.
    def ident(name)
      parts = name.to_s.split(%r{(?<=::|/)})
      last = parts.pop
      %(#{%(<span class="ns">#{esc(parts.join)}</span>) unless parts.empty?}<span class="leaf">#{esc(last)}</span>)
    end

    def link_to(obj, depth, text = nil)
      %(<a href="#{'../' * depth}#{obj.url}">#{text || esc(obj.name)}</a>)
    end

    def anchor(id, label = 'Link to this section')
      %(<a class="anchor" href="##{esc(id)}" aria-label="#{esc(label)}">#</a>)
    end

    def counts_text(counts)
      return '' if counts.nil? || counts.empty?

      counts.sort.map { |k, v| "#{v} #{plural(k, v)}" }.join(', ')
    end

    def plural(label, count)
      return label if count == 1

      label.end_with?('s') ? "#{label}es" : "#{label}s"
    end

    def meter(percent)
      p = percent.to_i.clamp(0, 100)
      tone = if p >= 90
               'good'
             elsif p >= 60
               'fair'
             else
               'poor'
             end
      %(<span class="meter meter-#{tone}" role="img" aria-label="#{p}% documented"><span style="width: #{p}%"></span></span>)
    end

    # The dependency a module's metadata names, matched to a module in this
    # environment when there is one.
    def dependency(dep, env)
      slug = dep['name'].to_s.tr('/', '-')
      short_name = slug.split('-', 2).last
      [slug, env.module_named(short_name)]
    end

    def supported_os(metadata)
      Array(metadata['operatingsystem_support']).map do |os|
        [os['operatingsystem'].to_s, Array(os['operatingsystemrelease']).join(', ')]
      end
    end

    def kind_order = Docs::KINDS

    private

    def linker(env, depth)
      lambda { |text|
        obj = env.lookup(text)
        obj && "#{'../' * depth}#{obj.url}"
      }
    end

    def template(name)
      @templates[name] ||= ERB.new(File.read(File.join(@config.templates_dir, "#{name}.html.erb")), trim_mode: '-')
    end

    def load_environment(dir, manifest)
      mods = manifest['modules'].select { |m| m['status'] == 'ok' }.filter_map do |entry|
        mdir = File.join(dir, 'modules', entry['name'])
        readme = %w[README.md README.txt].map { |f| File.join(mdir, f) }.find { |f| File.exist?(f) }
        Docs::Mod.new(entry, read_json(File.join(mdir, 'strings.json'), entry['name']),
                      read_json(File.join(mdir, 'metadata.json'), entry['name']),
                      readme && [File.extname(readme), File.read(readme, encoding: 'UTF-8').scrub])
      rescue StandardError => e
        fail_module(entry, mdir, e)
      end
      Docs::Environment.new(mods)
    end

    def fail_module(entry, mdir, err)
      Log.warn("#{entry['name']}: cannot render its documentation: #{err.class}: #{err.message}")
      FileUtils.rm_rf(Dir.glob(File.join(mdir, '*')) - [File.join(mdir, 'strings.json')])
      entry.merge!('status' => 'failed', 'phase' => 'render', 'error' => "#{err.class}: #{err.message}", 'transient' => false)
      entry.delete('index')
      nil
    end

    def read_json(path, mod)
      File.exist?(path) ? JSON.parse(File.read(path)) : nil
    rescue JSON::ParserError => e
      Log.warn("#{mod}: unreadable #{File.basename(path)}: #{e.message}")
      nil
    end

    # Counts, coverage, and what changed, recorded in the manifest so the
    # dashboard, build.json, and the next build can all use them.
    def annotate(manifest, env, previous)
      env.modules.each do |mod|
        entry = mod.entry
        entry['counts'] = mod.objects.group_by { |o| o.kind.label }.transform_values(&:size)
        entry['coverage'] = mod.coverage
        entry['summary'] = mod.summary unless mod.summary.empty?
      end
      manifest['coverage'] = env.coverage
      return unless previous

      diff = Docs.diff(Docs.module_map(previous), Docs.module_map(manifest))
      manifest['changes'] = {
        'since' => previous['built_at'], 'from_commit' => previous.dig('provenance', 'commit'),
        'to_commit' => manifest.dig('provenance', 'commit'),
        'previous_modules' => Docs.module_map(previous).select { |n, _| diff['changed'].key?(n) || diff['removed'].include?(n) }
      }.merge(diff.except('same'))
    end

    def live_manifests(envs)
      envs.filter_map do |name, e|
        next unless e['build']

        path = File.join(@config.builds_dir, e['build'], 'build.json')
        [name, JSON.parse(File.read(path))] if File.exist?(path)
      rescue JSON::ParserError
        nil
      end.to_h
    end
  end
end
