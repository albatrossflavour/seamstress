# frozen_string_literal: true

# Reads an environment's Hiera hierarchy and data into the index the Hiera
# page works from: the levels in order, every data file's keys, and what each
# merged key comes to for every set of files that can apply at once. A string
# that holds eyaml ciphertext is dropped here, whole, so none is ever
# published, and nothing is decrypted.

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
    # eyaml decrypts an ENC[...] block wherever it sits in a string, so the
    # opening of one anywhere marks the whole string as a secret.
    CIPHERTEXT = 'ENC['
    BACKEND_KEYS = %w[data_hash lookup_key data_dig].freeze
    # A hierarchy entry can name two kinds of backend that defaults cannot.
    ENTRY_BACKEND_KEYS = (BACKEND_KEYS + %w[hiera3_backend v4_data_hash]).freeze
    PATH_KEYS = %w[path paths].freeze
    OTHER_LOCATIONS = %w[glob globs mapped_paths uri uris].freeze
    # What Puppet takes for a defaults block or a hierarchy that is not there
    # (HieraConfigV5::DEFAULT_CONFIG_HASH).
    DEFAULTS = { 'datadir' => 'data', 'data_hash' => 'yaml_data' }.freeze
    HIERARCHY = [{ 'name' => 'Common', 'path' => 'common.yaml' }].freeze
    NO_BACKEND = 'no backend is named for it or in defaults, which Puppet refuses'
    LINKED_OUT = 'its datadir links outside the environment'

    module_function

    # Returns the index for the environment at root, or nil when it has no
    # Hiera 5 configuration. samples is name => { variable => value }, and
    # values is variable => [more values to offer for it], of which at most
    # limit are kept for each.
    def index(root, environment:, samples: {}, values: {}, limit: 200)
      config_path = File.join(root, 'hiera.yaml')
      return nil unless File.file?(config_path) && !File.symlink?(config_path)

      config = HieraFiles.load_yaml(File.read(config_path))
      return nil unless config.is_a?(Hash) && config['version'] == 5

      reader = HieraReader.new(root)
      levels = levels_for(config, reader)
      data = reader.data
      notes = reader.notes
      claim_files(levels, data)
      options = HieraMerges.lookup_options(levels, data)
      merged = HieraMerges.merged_values(levels, data, options, notes)
      {
        'environment' => environment, 'levels' => levels, 'data' => data, 'lookup_options' => options, 'merged' => merged,
        'samples' => stringify(samples), 'values' => offered(values, limit, notes), 'notes' => notes.uniq
      }
    end

    # One level per path, in hierarchy order, each with the data files that
    # exist under it and the variable values those file names imply. What
    # hiera.yaml leaves out is what Puppet would take: its defaults for no
    # defaults block, and one level, common.yaml, for no hierarchy.
    def levels_for(config, reader)
      defaults = config['defaults'] || DEFAULTS
      Array(config['hierarchy'] || HIERARCHY).flat_map do |entry|
        base = level_base(entry, defaults)
        paths = PATH_KEYS.flat_map { |k| Array(entry[k]) }
        why = unreadable_reason(entry, base, paths, reader)
        reader.notes << "The datadir #{base['datadir']} links outside the environment, so it is not read." if why == LINKED_OUT
        next [unreadable_level(base, entry, paths, why)] if why

        paths.map { |path| readable_level(base, path.to_s, reader) }
      end
    end

    # What every level from one hierarchy entry shares: its name, and its
    # backend and datadir, from defaults when the entry does not say.
    def level_base(entry, defaults)
      backend = ENTRY_BACKEND_KEYS.filter_map { |k| entry[k] }.first || BACKEND_KEYS.filter_map { |k| defaults[k] }.first
      datadir = (entry['datadir'] || defaults['datadir'] || DEFAULTS['datadir']).to_s.sub(%r{/+\z}, '')
      { 'name' => entry['name'].to_s, 'backend' => backend.to_s, 'datadir' => datadir }
    end

    # Why a hierarchy entry cannot be read, or nil when it can. Puppet fails a
    # hiera.yaml whose defaults block is there and names no backend, for an
    # entry that names none either, so there is nothing to assume for one.
    def unreadable_reason(entry, base, paths, reader)
      backend, datadir = base.values_at('backend', 'datadir')
      if backend.empty? then NO_BACKEND
      elsif !READABLE.include?(backend) then "the #{backend} backend is not read"
      elsif paths.empty? then "#{(OTHER_LOCATIONS & entry.keys).first || 'this kind of location'} is not read, only path and paths"
      elsif HieraFiles.outside?(datadir) then 'its data is outside the environment'
      elsif datadir.include?('%{') then 'its datadir is interpolated'
      elsif reader.linked_out?(datadir) then LINKED_OUT
      end
    end

    def unreadable_level(base, entry, paths, why)
      shown = paths.first || OTHER_LOCATIONS.filter_map { |k| Array(entry[k]).first }.first
      # A uri can carry a password or a token, which is no part of saying where the level is.
      place = shown.to_s.sub(%r{//[^/@\s]*@}, '//').sub(/[?#].*\z/m, '')
      base.merge('path' => place, 'vars' => [], 'files' => [], 'readable' => false, 'reason' => why)
    end

    # A file that could not be read is left out of the level's files, so its
    # name is not offered as a value for a variable.
    def readable_level(base, path, reader)
      vars = path.scan(/%\{([^}]+)\}/).flatten.map(&:strip)
      pattern = Regexp.new("\\A#{Regexp.escape(path).gsub(/%\\\{[^}]+\\\}/, '(.+?)')}\\z")
      files = reader.files(base['datadir']).filter_map do |rel|
        match = pattern.match(rel)
        full = "#{base['datadir']}/#{rel}"
        { 'file' => full, 'vars' => vars.zip(match.captures).to_h } if match && reader.read?(full)
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

    # The values to offer for each variable, cut to the first `limit` in
    # order, with a note for each one that was cut. A large estate has more
    # certnames than a list is any use for, and every one is in the index.
    def offered(values, limit, notes)
      (values || {}).to_h do |name, list|
        all = Array(list).map(&:to_s).reject(&:empty?).uniq.sort
        cut = "#{name} has #{all.size} values, so the first #{limit} are offered. Any value can still be typed."
        notes << cut if all.size > limit
        [name.to_s, all.first(limit)]
      end
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

  # Reading an environment's hiera.yaml and finding its data files.
  module HieraFiles
    module_function

    # The datadirs hiera.yaml names, relative to the environment.
    def datadirs(text)
      config = load_yaml(text)
      return [] unless config.is_a?(Hash)

      default = (config['defaults'] || Hiera::DEFAULTS)['datadir'] || Hiera::DEFAULTS['datadir']
      dirs = Array(config['hierarchy'] || Hiera::HIERARCHY).map { |entry| (entry['datadir'] || default).to_s.sub(%r{/+\z}, '') }
      dirs.uniq.reject { |d| d.empty? || outside?(d) || d.include?('%{') }
    rescue Psych::Exception
      []
    end

    # A digest of hiera.yaml and everything under its datadirs, which changes
    # when the page would. It reads what the index reads and no more: a link
    # goes in as where it points, and a datadir that links out of the
    # environment as that fact alone.
    def digest(root)
      config = File.join(root, 'hiera.yaml')
      return nil unless File.file?(config) && !File.symlink?(config)

      text = File.read(config)
      out, dirs = datadirs(text).partition { |d| escapes?(root, File.join(root, d)) }
      files = dirs.flat_map { |d| Dir.glob(File.join(root, d, '**', '*')).select { |f| File.symlink?(f) || File.file?(f) } }.sort
      parts = [text] + out.map { |d| "#{d}\0outside" } + files.map { |f| "#{f.sub("#{root}/", '')}\0#{mark(f)}" }
      Digest::SHA256.hexdigest(parts.join("\n"))
    end

    def mark(file) = File.symlink?(file) ? "link #{File.readlink(file)}" : Digest::SHA256.file(file).hexdigest

    def load_yaml(text)
      YAML.safe_load(text, permitted_classes: [Symbol, Date, Time], aliases: true)
    end

    def outside?(datadir) = datadir.start_with?('/') || datadir.split('/').include?('..')

    # Whether path, with every link on the way followed, ends up outside
    # root. A path that is not there leads nowhere.
    def escapes?(root, path)
      real = File.realpath(path)
      base = File.realpath(root)
      real != base && !real.start_with?("#{base}/")
    rescue SystemCallError
      false
    end
  end

  # Reads an environment's data files for one index: each once, and none that
  # is a link or that a link takes out of the environment, since a link could
  # publish any file the build can read. What is left out gets a note.
  class HieraReader
    attr_reader :notes

    # The most every data file together may come to, counted as HieraCopy
    # counts one. Each file has its own limit, and a great many of them just
    # inside it would still be more than a browser should be sent.
    TOTAL = 64_000_000

    def initialize(root)
      @root = root
      @read = {}
      @notes = []
      @size = 0
    end

    # file => content, with a file that could not be read shown as empty.
    def data = @read.transform_values { |content| content || {} }

    def linked_out?(datadir) = HieraFiles.escapes?(@root, File.join(@root, datadir))

    # Everything under a datadir, relative to it.
    def files(datadir) = Dir.glob('**/*', base: File.join(@root, datadir)).sort

    # Whether the data file called name, a path within the environment, is
    # one the index holds the content of.
    def read?(name)
      path = File.join(@root, name)
      return false unless File.file?(path)

      if File.symlink?(path) || HieraFiles.escapes?(@root, path)
        @notes << "#{name} is a link or lies outside the environment, so it is not read."
        return false
      end
      @read[name] = load(path, name) unless @read.key?(name)
      !@read[name].nil?
    end

    private

    def load(path, name)
      content = HieraFiles.load_yaml(File.read(path, encoding: 'UTF-8'))
      content.is_a?(Hash) ? sized(content) : {}
    rescue HieraCopy::TooLarge, SystemStackError
      @notes << "#{name} comes to more than the index holds once its aliases are followed, so it is shown as empty."
      nil
    rescue HieraCopy::OddKey
      @notes << "#{name} has a key that is a list or a mapping, which Hiera cannot look up, so it is shown as empty."
      nil
    rescue Psych::Exception, SystemCallError, ArgumentError => e
      @notes << "#{name} could not be read as YAML, so it is shown as empty (#{e.class.name.split('::').last})."
      nil
    end

    # The file's content copied for the index, if there is still room for it.
    def sized(content)
      copier = HieraCopy.new
      copied = copier.copy(content)
      raise HieraCopy::TooLarge if @size + copier.size > TOTAL

      @size += copier.size
      copied
    end
  end

  # One data file's content as the index carries it: a string that holds
  # eyaml ciphertext replaced by ENCRYPTED, and the size of the whole counted
  # on the way. YAML aliases let a few hundred bytes stand for gigabytes, and
  # each use of one is written out in full here.
  class HieraCopy
    # The most one file may come to: a node counts one, and a string one more
    # for each byte, so the count is close to what the index will weigh.
    LIMIT = 8_000_000
    class TooLarge < StandardError; end
    # A mapping key that is itself a list or a mapping. YAML allows it and
    # Hiera has no use for it, and one built from aliases is as large as any
    # value while never being counted as one.
    class OddKey < StandardError; end

    attr_reader :size

    def self.weight(value) = 1 + (value.is_a?(String) ? value.bytesize : 0)

    def initialize
      @size = 0
    end

    def copy(value)
      count(value)
      case value
      when String, Symbol then text(value.to_s)
      when Array then value.map { |v| copy(v) }
      when Hash then copy_hash(value)
      when Date, Time then value.to_s
      # JSON has no infinity and no not-a-number, which YAML's .inf and .nan are.
      when Float then value.finite? ? value : value.to_s
      else value
      end
    end

    private

    def count(value)
      @size += self.class.weight(value)
      raise TooLarge if @size > LIMIT
    end

    def secret?(text) = text.include?(Hiera::CIPHERTEXT)

    # A string as JSON can carry it: YAML's !!binary gives bytes that need not
    # be text at all.
    def text(string)
      clean = string.encoding == Encoding::UTF_8 ? string.scrub('?') : string.dup.force_encoding(Encoding::UTF_8).scrub('?')
      secret?(clean) ? Hiera::ENCRYPTED : clean
    end

    def copy_hash(hash)
      hash.each_with_object({}) do |(key, value), out|
        raise OddKey if key.is_a?(Hash) || key.is_a?(Array)

        name = key.to_s.scrub('?')
        count(name)
        out[secret?(name) ? key_name(name, hash, out) : name] = copy(value)
      end
    end

    # A key that holds ciphertext is named for a digest of itself, so it is
    # the same key in every file that has it and still tells nothing. The
    # name grows until no other key in the hash has it.
    def key_name(key, hash, out)
      taken = (hash.keys.map(&:to_s) + out.keys).to_set
      digest = Digest::SHA256.hexdigest(key)
      (8..64).map { |n| "encrypted key #{digest[0, n]}" }.find { |name| !taken.include?(name) }
    end
  end

  # lookup_options and merging for the Hiera index. Merges are Puppet's own.
  module HieraMerges
    # A merged key set in more file combinations than this is left unmerged.
    MAX_COMBINATIONS = 4000
    # The most the values that go into every merge may come to, across the
    # index, counted as HieraCopy counts a file. A merged key is worked out
    # for thousands of combinations, each as large as the values in it.
    MAX_MERGED = 64_000_000

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
      keys = (data.values.flat_map(&:keys).uniq - ['lookup_options']).select { |k| merges?(options_for(options, k)['merge']) }
      room = MAX_MERGED
      keys.each_with_object({}) do |key, out|
        holders = by_level.map { |files| files.select { |f| data[f].key?(key) } }.reject(&:empty?)
        cost = merge_cost(key, holders, data, room, notes)
        merged = cost && merge_key(key, options_for(options, key)['merge'], holders, data, notes)
        next unless merged

        room -= cost
        out[key] = merged
      end
    end

    def merges?(merge) = ![nil, 'first'].include?(merge.is_a?(Hash) ? merge['strategy'] : merge)

    # What merging a key in every combination of its files takes of the room
    # left, or nil when one level at most sets it, and nil with a note when
    # it is too much to do.
    def merge_cost(key, holders, data, room, notes)
      return nil if holders.size < 2

      if holders.reduce(1) { |n, files| n * (files.size + 1) } > MAX_COMBINATIONS
        notes << "#{key} is set in too many files to merge every combination, so its merged value is not shown."
        return nil
      end
      weights = holders.flatten.to_h { |f| [f, weight(data[f][key])] }
      cost = combinations(holders).sum { |files| files.sum { |f| weights[f] } }
      return cost if cost <= room

      notes << "#{key} has merged values that would swell the index, so its merged value is not shown."
      nil
    end

    def weight(value)
      inner = case value
              when Array then value.sum { |v| weight(v) }
              when Hash then value.sum { |k, v| weight(k) + weight(v) }
              else 0
              end
      HieraCopy.weight(value) + inner
    end

    # One key's merged value for each set of its files, or nil with a note.
    def merge_key(key, merge, holders, data, notes)
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
