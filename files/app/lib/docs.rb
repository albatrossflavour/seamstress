# frozen_string_literal: true

require 'json'

module Seamstress
  # The documentation of one environment, read from each module's
  # puppet-strings JSON: every object, the links between them, what is and
  # is not documented, and the search index. Rendering lives elsewhere; this
  # is the model the pages are drawn from.
  module Docs
    Kind = Struct.new(:key, :dir, :label, :plural)

    KINDS = [
      Kind.new('puppet_classes', 'classes', 'class', 'Classes'),
      Kind.new('defined_types', 'defined_types', 'defined type', 'Defined types'),
      Kind.new('resource_types', 'types', 'resource type', 'Resource types'),
      Kind.new('providers', 'providers', 'provider', 'Providers'),
      Kind.new('puppet_functions', 'functions', 'function', 'Functions'),
      Kind.new('puppet_tasks', 'tasks', 'task', 'Tasks'),
      Kind.new('puppet_plans', 'plans', 'plan', 'Plans'),
      Kind.new('data_type_aliases', 'type_aliases', 'type alias', 'Type aliases'),
      Kind.new('data_types', 'data_types', 'data type', 'Data types')
    ].freeze

    KIND_BY_KEY = KINDS.to_h { |k| [k.key, k] }.freeze
    TYPE_KINDS = %w[data_type_aliases data_types].freeze
    PUPPET_SOURCE = %w[puppet_classes defined_types puppet_plans].freeze

    # One documented object: a class, a function, a task, and so on.
    class Obj
      attr_reader :kind, :mod, :data

      def initialize(kind, mod, data)
        @kind = kind
        @mod = mod
        @data = data
      end

      # Tasks are named by file; everything else carries its full name.
      def name
        @name ||= case kind.key
                  when 'puppet_tasks' then data['name'] == 'init' ? mod : "#{mod}::#{data['name']}"
                  when 'providers' then "#{data['type_name']}/#{data['name']}"
                  else data['name'].to_s
                  end
      end

      def file_name = "#{name.gsub('::', '.').tr('/', '-').gsub(/[^\w.-]/, '_')}.html"
      def url = "modules/#{mod}/#{kind.dir}/#{file_name}"
      def docstring = data['docstring'] || {}
      def text = docstring['text'].to_s
      def tags(tag = nil) = (docstring['tags'] || []).select { |t| tag.nil? || t['tag_name'] == tag }
      def tag_text(tag) = tags(tag).first&.dig('text').to_s
      def private? = tag_text('api') == 'private'
      def deprecated = tags('deprecated').first && tag_text('deprecated')
      def file = data['file']
      def line = data['line'].to_i.positive? ? data['line'].to_i : nil
      def source = data['source']

      def summary
        s = tag_text('summary').strip
        s.empty? ? text.split(/\n\s*\n/).first.to_s.strip : s
      end

      # The description, unless it is only the summary again.
      def description
        tag_text('summary').strip.empty? && text.split(/\n\s*\n/).size <= 1 ? '' : text
      end

      def source_lang
        if file.to_s.end_with?('.rb') then 'ruby'
        elsif file.to_s.end_with?('.json') then 'json'
        else 'puppet'
        end
      end

      def examples
        sigs = kind.key == 'puppet_functions' ? Array(data['signatures']).flat_map { |s| s.dig('docstring', 'tags') || [] } : []
        (tags('example') + sigs.select { |t| t['tag_name'] == 'example' }).uniq { |t| t['text'] }
                                                                          .map { |t| [t['name'].to_s, t['text'].to_s] }
      end

      # Parameters as rows: name, type, default, description, required.
      def params
        @params ||= case kind.key
                    when 'puppet_classes', 'defined_types', 'puppet_plans' then manifest_params
                    when 'puppet_tasks' then task_params
                    when 'resource_types' then type_attrs('parameters') + type_attrs('properties')
                    else []
                    end
      end

      def signatures
        Array(data['signatures']).map do |s|
          tags = s.dig('docstring', 'tags') || []
          {
            signature: s['signature'].to_s, text: s.dig('docstring', 'text').to_s,
            params: tags.select { |t| t['tag_name'] == 'param' }.map { |t| param_row(t, nil, true) },
            returns: tags.select { |t| t['tag_name'] == 'return' }
          }
        end
      end

      def options_for(param)
        tags('option').select { |t| t['name'] == param }
      end

      # Tags with no section of their own, shown as notes.
      def notes
        (tags('note') + tags('see') + tags('since') + tags('raise') + tags('todo') + tags('author'))
      end

      # [label, documented?] for everything that ought to be described.
      def coverage_items
        items = [['summary', !summary.empty?]]
        rows = kind.key == 'puppet_functions' ? signatures.flat_map { |s| s[:params] } : params
        items + rows.reject { |p| p[:name] == 'provider' }.map { |p| ["$#{p[:name]}", !p[:text].strip.empty?] }
      end

      def missing = coverage_items.reject(&:last).map(&:first)

      private

      def manifest_params
        defaults = data['defaults'] || {}
        rows = tags('param').map { |t| param_row(t, defaults[t['name']], !defaults.key?(t['name'])) }
        known = rows.map { |r| r[:name] }
        rows + defaults.except(*known).map { |n, d| { name: n, types: '', default: d, text: '', required: false } }
      end

      def task_params
        tags('param').map do |t|
          row = param_row(t, nil, true)
          row.merge(required: !row[:types].start_with?('Optional['))
        end
      end

      def param_row(tag, default, required)
        { name: tag['name'].to_s, types: Array(tag['types']).join(', '), default: default, text: tag['text'].to_s, required: required }
      end

      def type_attrs(which)
        Array(data[which]).map do |a|
          {
            name: a['name'].to_s, types: '', default: a['default']&.to_s, text: a['description'].to_s, required: false,
            attribute: which == 'properties' ? 'property' : 'parameter', namevar: a['isnamevar'] ? true : false,
            values: Array(a['values']).map(&:to_s)
          }
        end
      end
    end

    # One module in an environment: its build entry, objects, and metadata.
    class Mod
      attr_reader :entry, :objects, :metadata, :readme

      def initialize(entry, strings, metadata, readme)
        @entry = entry
        @metadata = metadata || {}
        @readme = readme
        @objects = KINDS.flat_map { |k| Array(strings && strings[k.key]).map { |d| Obj.new(k, name, d) } }
                        .sort_by { |o| [KINDS.index(o.kind), o.name.downcase] }
      end

      def name = entry['name']
      def url = "modules/#{name}/index.html"
      def summary = metadata['summary'].to_s
      def by_kind = objects.group_by(&:kind)

      def coverage
        items = objects.flat_map(&:coverage_items)
        Docs.coverage(items)
      end

      def gaps = objects.reject { |o| o.missing.empty? }
    end

    # Documented and total, as a hash with a percentage.
    def self.coverage(items)
      done = items.count(&:last)
      { 'documented' => done, 'total' => items.size, 'percent' => items.empty? ? 100 : (100.0 * done / items.size).floor }
    end

    # Every module of one environment, with lookups across all of them.
    class Environment
      def initialize(modules)
        @modules = modules
        @by_name = {}
        @types = {}
        objects.each do |o|
          if TYPE_KINDS.include?(o.kind.key) then @types[o.name] ||= o
          elsif o.kind.key != 'providers' then @by_name[o.name.downcase] ||= o
          end
        end
        @mods = modules.to_h { |m| [m.name, m] }
      end

      # Modules whose pages exist: one that failed to render drops out.
      def modules = @modules.select { |m| m.entry['status'] == 'ok' }
      def objects = modules.flat_map(&:objects)
      def module_named(name) = @mods[name]
      def type_named(name) = @types[name]

      # An object an inline code span names: a class, a function, a type
      # alias, a module, written as it would be in Puppet code.
      def lookup(text)
        t = text.to_s.strip.sub(/\A(?:::|\$)/, '').sub(/\(\)\z/, '')
        return @types[t] if @types[t]

        t = Regexp.last_match(1) if t =~ /\A(?:Class|Resource)\['(?:::)?([\w:]+)'\]\z/i
        @by_name[t.downcase]
      end

      # Objects named in a Puppet object's source: included classes,
      # declared defined types and resource types, called functions, run
      # tasks and plans, and type aliases. Not the object itself.
      def uses(obj)
        @uses ||= {}
        @uses[obj] ||= begin
          found = referenced(obj)
          found.delete(obj)
          found.sort_by { |o| [KINDS.index(o.kind), o.name] }
        end
      end

      def used_by(obj)
        @used_by ||= objects.each_with_object(Hash.new { |h, k| h[k] = [] }) do |o, acc|
          uses(o).each { |u| acc[u] << o }
        end
        @used_by[obj]
      end

      def coverage = Docs.coverage(objects.flat_map(&:coverage_items))

      # Entries for the command palette: every module, object, and
      # parameter. Keys are short because the file is loaded on every page.
      def search_entries
        modules.flat_map do |m|
          [{ 'n' => m.name, 'k' => 'module', 'm' => m.name, 's' => short(m.summary), 'u' => m.url }] +
            m.objects.flat_map do |o|
              [{ 'n' => o.name, 'k' => o.kind.label, 'm' => m.name, 's' => short(o.summary), 'u' => o.url }] +
                o.params.map do |p|
                  { 'n' => p[:name], 'k' => 'parameter', 'm' => m.name, 'p' => o.name, 's' => short(p[:text]),
                    'u' => "#{o.url}#p-#{p[:name]}" }
                end
            end
        end
      end

      private

      def short(text)
        text.to_s.gsub(/\[([^\]]+)\]\([^)]*\)/, '\\1').delete('`').gsub(/\s+/, ' ').strip[0, 160]
      end

      def referenced(obj)
        types = obj.params.map { |p| p[:types] }.join(' ')
        found = types.scan(/\b[A-Z]\w*(?:::[A-Z]\w*)+/).filter_map { |t| @types[t] }
        return found.uniq unless obj.source && (PUPPET_SOURCE.include?(obj.kind.key) || obj.source_lang == 'puppet')

        src = obj.source.gsub(/#[^\n]*/, '')
        names = src.scan(/(?<![\w$:])(?:::)?([a-z]\w*(?:::[a-z]\w*)+)/).flatten
        names += src.scan(/\b(?:include|contain|require)\s+['"]?(?:::)?([a-z]\w*)/).flatten
        names += src.scan(/\bclass\s*\{\s*['"](?:::)?([a-z]\w*)['"]/).flatten
        names += src.scan(/(?<![\w$:.])([a-z]\w*)\s*(?:\(|\{)/).flatten
        found += names.uniq.filter_map { |n| @by_name[n.downcase] }
        found += src.scan(/\b[A-Z]\w*(?:::[A-Z]\w*)+/).filter_map { |t| @types[t] }
        found.uniq
      end
    end

    # What differs between two sets of modules, each { name => details }.
    # A module has changed when its version, resolved SHA, ref, or source
    # moved. A control-repo module's ref is the control repo's own commit,
    # which moves whenever anything in the repo does, so for those only the
    # SHA (the module's tree) counts.
    def self.diff(left, right)
      changed = (left.keys & right.keys).sort.filter_map do |n|
        keys = left[n]['kind'] == 'control' && right[n]['kind'] == 'control' ? %w[version sha kind source] : %w[version sha ref kind source]
        fields = keys.reject { |k| left[n][k].to_s == right[n][k].to_s }
        [n, fields] unless fields.empty?
      end
      {
        'changed' => changed.to_h,
        'added' => (right.keys - left.keys).sort,
        'removed' => (left.keys - right.keys).sort,
        'same' => ((left.keys & right.keys) - changed.map(&:first)).sort
      }
    end

    # The comparable view of a build manifest's modules.
    def self.module_map(manifest)
      Array(manifest && manifest['modules']).to_h do |m|
        [m['name'], m.slice('version', 'sha', 'ref', 'kind', 'source', 'status')]
      end
    end
  end
end
