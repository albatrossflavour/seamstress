# frozen_string_literal: true

# Reads an environment's Hiera hierarchy and data into the index the Hiera
# page works from: the levels in order, every data file's keys, and what each
# merged key comes to for every set of files that can apply at once. Values
# that are eyaml ciphertext are dropped here, so none is ever published, and
# nothing is decrypted.

require 'digest'
require 'yaml'
require 'date'

module Seamstress
  # An environment's Hiera hierarchy and data, as the index the Hiera page
  # reads.
  module Hiera
    # Backends whose data files are plain YAML this can read.
    READABLE = %w[yaml_data eyaml_lookup_key].freeze
    # What stands in for an encrypted value in the index.
    ENCRYPTED = { '__enc' => true }.freeze
    CIPHERTEXT = /\AENC\[/
    BACKEND_KEYS = %w[data_hash lookup_key data_dig].freeze
    PATH_KEYS = %w[path paths].freeze
    OTHER_LOCATIONS = %w[glob globs mapped_paths uri uris].freeze

    module_function

    # Returns the index for the environment at root, or nil when it has no
    # Hiera 5 configuration. samples is name => { variable => value }, and
    # values is variable => [more values to offer for it].
    def index(root, environment:, samples: {}, values: {})
      config_path = File.join(root, 'hiera.yaml')
      return nil unless File.file?(config_path)

      config = HieraFiles.load_yaml(File.read(config_path))
      return nil unless config.is_a?(Hash) && config['version'] == 5

      notes = []
      data = {}
      levels = levels_for(root, config, data, notes)
      claim_files(levels, data)
      options = HieraMerges.lookup_options(levels, data)
      {
        'environment' => environment, 'levels' => levels, 'data' => data, 'lookup_options' => options,
        'merged' => HieraMerges.merged_values(levels, data, options, notes),
        'samples' => stringify(samples), 'values' => offered(values), 'notes' => notes
      }
    end

    # One level per path, in hierarchy order, each with the data files that
    # exist under it and the variable values those file names imply.
    def levels_for(root, config, data, notes)
      defaults = config['defaults'] || {}
      Array(config['hierarchy']).flat_map do |entry|
        backend = BACKEND_KEYS.filter_map { |k| entry[k] }.first || BACKEND_KEYS.filter_map { |k| defaults[k] }.first
        datadir = (entry['datadir'] || defaults['datadir'] || 'data').to_s.sub(%r{/+\z}, '')
        paths = PATH_KEYS.flat_map { |k| Array(entry[k]) }
        base = { 'name' => entry['name'].to_s, 'backend' => backend.to_s, 'datadir' => datadir }
        why = unreadable_reason(entry, backend, datadir, paths)
        next [unreadable_level(base, entry, paths, why)] if why

        paths.map { |path| readable_level(root, base, path.to_s, data, notes) }
      end
    end

    # Why a hierarchy entry cannot be read, or nil when it can.
    def unreadable_reason(entry, backend, datadir, paths)
      if !READABLE.include?(backend) then "the #{backend} backend is not read"
      elsif paths.empty? then "#{(OTHER_LOCATIONS & entry.keys).first || 'this kind of location'} is not read, only path and paths"
      elsif HieraFiles.outside?(datadir) then 'its data is outside the environment'
      elsif datadir.include?('%{') then 'its datadir is interpolated'
      end
    end

    def unreadable_level(base, entry, paths, why)
      shown = paths.first || OTHER_LOCATIONS.filter_map { |k| Array(entry[k]).first }.first
      base.merge('path' => shown.to_s, 'vars' => [], 'files' => [], 'readable' => false, 'reason' => why)
    end

    def readable_level(root, base, path, data, notes)
      vars = path.scan(/%\{([^}]+)\}/).flatten.map(&:strip)
      pattern = Regexp.new("\\A#{Regexp.escape(path).gsub(/%\\\{[^}]+\\\}/, '(.+?)')}\\z")
      dir = File.join(root, base['datadir'])
      files = Dir.glob('**/*', base: dir).sort.filter_map do |rel|
        match = pattern.match(rel)
        next unless match && File.file?(File.join(dir, rel))

        full = "#{base['datadir']}/#{rel}"
        data[full] ||= HieraFiles.read_data(File.join(dir, rel), full, notes)
        { 'file' => full, 'vars' => vars.zip(match.captures).to_h }
      end
      base.merge('path' => path, 'vars' => vars, 'files' => files, 'readable' => true)
    end

    # A file can fit two levels' patterns: os/RedHat-9.yaml also fits
    # os/%{family}.yaml with family "RedHat-9". The more specific level, the
    # earlier one, keeps it, so the values offered for a variable are real.
    def claim_files(levels, data)
      claimed = {}
      levels.each do |level|
        level['files'].reject! { |f| claimed[f['file']] && !level['vars'].empty? && claimed[f['file']] != level['path'] }
        level['files'].each do |f|
          claimed[f['file']] ||= level['path']
          f['keys'] = (data[f['file']].keys - ['lookup_options']).size
        end
      end
    end

    def offered(values)
      (values || {}).to_h { |name, list| [name.to_s, Array(list).map(&:to_s).reject(&:empty?).uniq.sort] }
    end

    def stringify(samples)
      (samples || {}).to_h { |name, vars| [name.to_s, (vars || {}).to_h { |k, v| [k.to_s, v.to_s] }] }
    end

    # What the manifest records about the index.
    def summary(index)
      { 'levels' => index['levels'].size, 'files' => index['data'].size,
        'keys' => (index['data'].values.flat_map(&:keys).uniq - ['lookup_options']).size }
    end
  end

  # Reading an environment's hiera.yaml and data files.
  module HieraFiles
    module_function

    # The datadirs hiera.yaml names, relative to the environment.
    def datadirs(text)
      config = load_yaml(text)
      return [] unless config.is_a?(Hash)

      default = config.dig('defaults', 'datadir') || 'data'
      dirs = Array(config['hierarchy']).map { |entry| (entry['datadir'] || default).to_s.sub(%r{/+\z}, '') }
      dirs.uniq.reject { |d| d.empty? || outside?(d) || d.include?('%{') }
    rescue Psych::Exception
      []
    end

    # A digest of hiera.yaml and everything under its datadirs, which changes
    # when the page would.
    def digest(root)
      config = File.join(root, 'hiera.yaml')
      return nil unless File.file?(config)

      text = File.read(config)
      files = datadirs(text).flat_map { |d| Dir.glob(File.join(root, d, '**', '*')).select { |f| File.file?(f) } }.sort
      Digest::SHA256.hexdigest(([text] + files.map { |f| "#{f.sub("#{root}/", '')}\0#{Digest::SHA256.file(f).hexdigest}" }).join("\n"))
    end

    def load_yaml(text)
      YAML.safe_load(text, permitted_classes: [Symbol, Date, Time], aliases: true)
    end

    def outside?(datadir) = datadir.start_with?('/') || datadir.split('/').include?('..')

    def read_data(path, name, notes)
      content = load_yaml(File.read(path, encoding: 'UTF-8'))
      content.is_a?(Hash) ? strip(content) : {}
    rescue Psych::Exception, SystemCallError, ArgumentError => e
      notes << "#{name} could not be read as YAML, so it is shown as empty (#{e.class.name.split('::').last})."
      {}
    end

    # The same value with every eyaml ciphertext replaced by ENCRYPTED.
    def strip(value)
      case value
      when String then value.lstrip.match?(Hiera::CIPHERTEXT) ? Hiera::ENCRYPTED : value
      when Array then value.map { |v| strip(v) }
      when Hash then value.to_h { |k, v| [k.to_s, strip(v)] }
      when Symbol, Date, Time then value.to_s
      else value
      end
    end
  end

  # lookup_options and merging for the Hiera index. Merges are Puppet's own.
  module HieraMerges
    # A merged key set in more file combinations than this is left unmerged.
    MAX_COMBINATIONS = 4000

    module_function

    # lookup_options from every data file, the higher levels' winning. Hiera
    # resolves them per node, which this does not, so two files that disagree
    # about a key's merge are settled in favour of the more specific level.
    def lookup_options(levels, data)
      files = levels.flat_map { |l| l['files'].map { |f| f['file'] } }.uniq
      files.reverse.each_with_object({}) do |file, all|
        found = data[file]['lookup_options']
        next unless found.is_a?(Hash)

        found.each { |key, opts| all[key] = (all[key] || {}).merge(opts) if opts.is_a?(Hash) }
      end
    end

    def options_for(options, key)
      return options[key] if options.key?(key)

      pattern = options.keys.find { |k| k.start_with?('^') && safe_match?(k, key) }
      pattern ? options[pattern] : {}
    end

    def safe_match?(pattern, key)
      Regexp.new(pattern).match?(key)
    rescue RegexpError
      false
    end

    # key => { "fileA\nfileB" => merged value } for every key whose merge is
    # not first-found and that more than one file sets. The files are in
    # hierarchy order, so the page builds the same string from the files that
    # apply to its sample node and reads the answer off.
    def merged_values(levels, data, options, notes)
      by_level = levels.select { |l| l['readable'] }.map { |l| l['files'].map { |f| f['file'] } }
      keys = data.values.flat_map(&:keys).uniq - ['lookup_options']
      keys.each_with_object({}) do |key, out|
        merge = options_for(options, key)['merge']
        next unless merges?(merge)

        holders = by_level.map { |files| files.select { |f| data[f].key?(key) } }.reject(&:empty?)
        merged = holders.size > 1 && merge_key(key, merge, holders, data, notes)
        out[key] = merged if merged
      end
    end

    def merges?(merge) = ![nil, 'first'].include?(merge.is_a?(Hash) ? merge['strategy'] : merge)

    # One key's merged value for each set of its files, or nil with a note.
    def merge_key(key, merge, holders, data, notes)
      if holders.reduce(1) { |n, files| n * (files.size + 1) } > MAX_COMBINATIONS
        notes << "#{key} is set in too many files to merge every combination, so its merged value is not shown."
        return nil
      end
      combinations(holders).to_h { |files| [files.join("\n"), merge_all(merge, files.map { |f| data[f][key] })] }
    rescue LoadError, ArgumentError, TypeError, RuntimeError => e
      notes << "#{key} could not be merged (#{e.message.lines.first.to_s.strip}), so its merged value is not shown."
      nil
    end

    # Every way of taking at most one file from each level, two or more deep.
    def combinations(holders)
      holders.reduce([[]]) { |sets, files| sets.flat_map { |set| [set] + files.map { |f| set + [f] } } }.select { |set| set.size > 1 }
    end

    # Puppet's own merge, highest priority first, so the result is Hiera's.
    def merge_all(merge, values)
      require 'puppet'
      strategy = Puppet::Pops::MergeStrategy.strategy(merge)
      values.map { |v| Marshal.load(Marshal.dump(v)) }.reduce { |memo, value| strategy.merge(memo, value) }
    end
  end
end
