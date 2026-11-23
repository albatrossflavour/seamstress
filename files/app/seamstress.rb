#!/opt/puppetlabs/puppet/bin/ruby
# frozen_string_literal: true

# seamstress builds a puppet-strings documentation site for every
# environment of a Puppet control repo.
#
# Two sources are supported. In git mode it polls the control repo with
# `git ls-remote`, reads each branch's Puppetfile, and resolves every module
# to a commit or a Forge release. In directory mode it reads environments
# that are already on disk (or unpacks a tarball per environment), and takes
# provenance from .r10k-deploy.json when there is one.
#
# Each environment is rebuilt only when its inputs change. Every module gets
# its own puppet-strings run, so one broken module stays contained. A build
# goes into builds/<env>-<fingerprint> and a symlink is swapped atomically,
# so a failed build leaves the last good one live.
#
# Usage: seamstress.rb --config /etc/seamstress/config.json [--force]
#                        [--environment NAME]

require 'digest'
require 'erb'
require 'fileutils'
require 'json'
require 'net/http'
require 'open3'
require 'optparse'
require 'time'
require 'uri'
require_relative 'lib/render'
require_relative 'lib/hiera'

# Everything the build needs, in one file so it can be copied to a node and
# run by Puppet's Ruby with no load path.
module Seamstress
  VERSION = '0.4.0'

  class Error < StandardError; end

  # A failure tied to one stage of one module. Fetch failures are worth
  # retrying on the next poll; strings failures are not, because the same
  # input produces the same result.
  class ModuleError < Error
    attr_reader :phase

    def initialize(phase, message)
      @phase = phase
      super(message)
    end

    def transient?
      %w[resolve fetch build].include?(phase)
    end
  end

  # Logging to stderr. Under systemd the <N> prefixes become journal
  # priorities; on a terminal they are left off.
  module Log
    LEVELS = { error: 3, warn: 4, info: 6, debug: 7 }.freeze

    class << self
      attr_writer :io, :debug

      def io
        @io ||= $stderr
      end

      def error(msg) = write(:error, msg)
      def warn(msg) = write(:warn, msg)
      def info(msg) = write(:info, msg)
      def debug(msg) = (@debug ? write(:debug, msg) : nil)

      private

      def write(level, msg)
        prefix = io.respond_to?(:tty?) && io.tty? ? "#{level}: " : "<#{LEVELS[level]}>"
        msg.to_s.each_line { |line| io.puts("#{prefix}#{line.chomp}") }
      end
    end
  end

  # Strips credentials from anything that looks like a URL before it reaches
  # a log line or a page.
  def self.redact(text)
    text.to_s.gsub(%r{(\b[a-z][a-z0-9+.-]*://)[^/@\s]+@}i, '\1***@')
  end

  def self.sha256(data) = Digest::SHA256.hexdigest(data)

  # A digest of this script and everything installed beside it: its
  # libraries, templates, and assets. It is part of every build's
  # fingerprint, so a change to how pages are drawn redraws them, whether or
  # not the version moved.
  def self.generator_digest(dir = __dir__)
    @generator_digests ||= {}
    @generator_digests[dir] ||= begin
      files = Dir.glob(File.join(dir, '**', '*')).select { |f| File.file?(f) }.sort
      sha256(files.map { |f| "#{f.delete_prefix("#{dir}/")}\0#{Digest::SHA256.file(f).hexdigest}" }.join("\n"))
    end
  end

  def self.atomic_write(path, content, mode: 0o644)
    tmp = "#{path}.tmp-#{Process.pid}"
    File.write(tmp, content)
    File.chmod(mode, tmp)
    File.rename(tmp, path)
  ensure
    FileUtils.rm_f(tmp) if tmp && File.exist?(tmp)
  end

  # Settings, read from the JSON file Puppet writes. Every key has a default
  # here so the script can also be run by hand with a minimal file.
  class Config
    DEFAULTS = {
      'source' => 'git',
      'control_repo' => nil,
      'code_dir' => nil,
      'tarballs' => {},
      'environments' => [],
      'exclude_environments' => [],
      'local_module_dirs' => %w[site-modules site],
      'docroot' => '/var/www/seamstress',
      'cache_dir' => '/var/lib/seamstress/cache',
      'state_file' => '/var/lib/seamstress/state.json',
      'puppet' => '/opt/puppetlabs/bin/puppet',
      'git' => 'git',
      'tar' => 'tar',
      'deploy_keys' => {},
      'known_hosts_file' => nil,
      'strict_host_key_checking' => 'accept-new',
      'forge_url' => 'https://forgeapi.puppet.com',
      'forge_token_file' => nil,
      'keep_builds' => 2,
      'module_timeout' => 600,
      'git_timeout' => 300,
      'metrics_file' => nil,
      'site_title' => 'seamstress',
      'hiera' => false,
      'hiera_samples' => {},
      'hiera_values' => {},
      'hiera_values_limit' => 200
    }.freeze

    attr_reader :data

    def self.load(path)
      new(JSON.parse(File.read(path)))
    end

    def initialize(data)
      @data = DEFAULTS.merge(data.compact)
      validate!
    end

    def [](key) = @data.fetch(key)

    def builds_dir = File.join(self['docroot'], 'builds')
    def links_dir = File.join(self['docroot'], 'environments')

    def assets_dir
      File.join(__dir__, 'assets')
    end

    def templates_dir
      File.join(__dir__, 'templates')
    end

    private

    def validate!
      case self['source']
      when 'git'
        raise Error, 'control_repo is required in git mode' if self['control_repo'].to_s.empty?
      when 'directory'
        raise Error, 'directory mode needs code_dir, tarballs, or both' if self['code_dir'].to_s.empty? && self['tarballs'].empty?
      else
        raise Error, "unknown source #{self['source'].inspect}; use git or directory"
      end
    end
  end

  # Runs external commands without a shell, with a timeout, capturing output.
  module Command
    # A command that exited non-zero or ran out of time.
    class Failed < Error
      attr_reader :stderr

      def initialize(cmd, status, stderr)
        @stderr = stderr.to_s
        tail = @stderr.lines.last(15).join.strip
        super(Seamstress.redact("#{cmd.join(' ')} #{status}#{": #{tail}" unless tail.empty?}"))
      end
    end

    def self.run(cmd, env: {}, chdir: nil, timeout: 300)
      opts = { pgroup: true }
      opts[:chdir] = chdir if chdir
      Open3.popen3(env, *cmd, **opts) do |stdin, stdout, stderr, thread|
        stdin.close
        out = Thread.new { stdout.read }
        err = Thread.new { stderr.read }
        unless thread.join(timeout)
          begin
            Process.kill('-KILL', thread.pid)
          rescue Errno::ESRCH
            nil
          end
          thread.join
          raise Failed.new(cmd, "timed out after #{timeout}s", err.value)
        end
        status = thread.value
        raise Failed.new(cmd, "exited #{status.exitstatus || status}", err.value) unless status.success?

        [out.value, err.value]
      end
    end
  end

  # Turns branch names into environment names the way r10k does, and applies
  # the allow and exclude lists.
  module Environments
    def self.name_for(branch) = branch.gsub(/\W/, '_')

    def self.select(names, allow, exclude)
      patterns = exclude.map { |e| Regexp.new(e) }
      names.select do |n|
        (allow.empty? || allow.include?(n)) && patterns.none? { |p| p.match?(n) }
      end
    end

    # Production first, then the rest alphabetically.
    def self.sort(names)
      names.sort_by { |n| [n == 'production' ? 0 : 1, n] }
    end
  end

  # Evaluates a Puppetfile the way r10k does: it is Ruby, so it runs. That is
  # the same trust r10k extends to the control repo, and it runs as the
  # unprivileged service user.
  class Puppetfile
    Mod = Struct.new(:name, :title, :type, :version, :options, keyword_init: true) do
      def git? = type == :git
      def forge? = type == :forge
      def local? = type == :local

      # owner-name for a Forge module.
      def slug = title.tr('/', '-')

      # The ref as written in the Puppetfile, for display.
      def declared_ref
        return version.to_s if forge?
        return 'local' if local?

        o = options
        (o[:commit] || o[:tag] || o[:branch] || o[:ref] || o[:default_branch_override] ||
         o[:default_branch] || 'HEAD').to_s
      end
    end

    attr_accessor :forge_url, :moduledir
    attr_reader :mods

    def self.parse(text, path = 'Puppetfile')
      pf = new
      DSL.new(pf).instance_eval(text, path)
      pf
    rescue SyntaxError, StandardError => e
      raise Error, "cannot parse #{path}: #{e.message.lines.first&.strip}"
    end

    def initialize
      @mods = []
      @forge_url = nil
      @moduledir = 'modules'
    end

    def add(title, args)
      opts = args.last.is_a?(Hash) ? args.pop.transform_keys(&:to_sym) : {}
      version = args.first
      name = title.to_s.split(%r{[/-]}).last
      type = if opts[:git] then :git
             elsif opts[:local] then :local
             elsif opts[:svn] then :svn
             elsif opts[:tarball] then :tarball
             elsif opts[:type] then opts[:type].to_sym
             else :forge
             end
      version ||= opts[:version] if type == :forge
      @mods << Mod.new(name: name, title: title.to_s, type: type, version: version || :latest, options: opts)
    end

    # The methods a Puppetfile may call. Anything else is ignored with a
    # warning rather than failing the whole environment.
    class DSL
      def initialize(puppetfile)
        @pf = puppetfile
      end

      def mod(title, *args) = @pf.add(title, args)
      def forge(url, *_rest) = (@pf.forge_url = url.to_s)
      def moduledir(dir) = (@pf.moduledir = dir.to_s)

      def method_missing(name, *_args)
        Log.warn("Puppetfile calls #{name}, which seamstress ignores")
        nil
      end

      def respond_to_missing?(*) = true
    end
  end

  # Git access: ls-remote, bare mirrors, and archives. Credentials are chosen
  # per URL, so two repos on one host can use two different deploy keys.
  class Git
    def initialize(config)
      @config = config
      @refs = {}
    end

    def env_for(url)
      ssh = ['ssh', '-F', '/dev/null', '-o', 'BatchMode=yes',
             '-o', "StrictHostKeyChecking=#{@config['strict_host_key_checking']}"]
      ssh += ['-o', "UserKnownHostsFile=#{@config['known_hosts_file']}"] if @config['known_hosts_file']
      key = key_for(url)
      ssh += ['-o', 'IdentitiesOnly=yes', '-i', key] if key
      {
        'GIT_SSH_COMMAND' => ssh.join(' '),
        'GIT_TERMINAL_PROMPT' => '0',
        'GIT_ASKPASS' => 'true'
      }
    end

    # The most specific matching pattern wins. A pattern is a URL or a shell
    # glob such as git@github.com:example/*.
    def key_for(url)
      match = @config['deploy_keys'].keys.select { |pat| File.fnmatch?(pat, url, File::FNM_EXTGLOB) }
                                    .max_by(&:length)
      match && @config['deploy_keys'][match]
    end

    # Every ref the remote has, as { ref => sha }, peeled tags included.
    # Cached for the length of one run.
    def ls_remote(url)
      @refs[url] ||= begin
        out, = git(url, 'ls-remote', url)
        out.lines.to_h { |l| l.chomp.split("\t", 2).reverse }
      end
    end

    def self.resolve_ref(refs, ref, kind = :ref)
      ref = ref.to_s
      return ref if ref.match?(/\A\h{40}\z/)

      candidates = case kind
                   when :branch then ["refs/heads/#{ref}"]
                   when :tag then ["refs/tags/#{ref}^{}", "refs/tags/#{ref}"]
                   else ["refs/heads/#{ref}", "refs/tags/#{ref}^{}", "refs/tags/#{ref}", ref]
                   end
      candidates.each { |c| return refs[c] if refs[c] }
      nil
    end

    def mirror_path(url) = File.join(@config['cache_dir'], 'git', "#{Seamstress.sha256(url)[0, 16]}.git")

    # Makes sure the mirror for url holds sha, fetching only when it does not.
    def ensure_commit(url, sha)
      dir = mirror_path(url)
      unless File.directory?(dir)
        FileUtils.mkdir_p(File.dirname(dir))
        run('init', '--bare', '--quiet', dir)
      end
      return dir if commit?(dir, sha)

      git(url, '-C', dir, 'fetch', '--prune', '--quiet', '--no-tags', url,
          '+refs/heads/*:refs/heads/*', '+refs/tags/*:refs/tags/*')
      raise Error, "commit #{sha} not found in #{Seamstress.redact(url)}" unless commit?(dir, sha)

      dir
    end

    def full_sha(url, short)
      dir = ensure_mirror_fetched(url)
      out, = run('-C', dir, 'rev-parse', '--verify', "#{short}^{commit}")
      out.strip
    end

    def show(dir, sha, path)
      out, = run('-C', dir, 'show', "#{sha}:#{path}")
      out
    rescue Command::Failed
      nil
    end

    # Subdirectories of path at sha, as { name => tree id }. The tree id is
    # a content hash of that directory, which makes a good cache key.
    def trees(dir, sha, path)
      out, = run('-C', dir, 'ls-tree', "#{sha}:#{path}")
      out.lines.filter_map do |l|
        meta, name = l.chomp.split("\t", 2)
        mode, type, id = meta.split
        [name, id] if type == 'tree' && mode == '040000'
      end.to_h
    rescue Command::Failed
      {}
    end

    def tree_id(dir, sha, path)
      out, = run('-C', dir, 'rev-parse', "#{sha}:#{path}")
      out.strip
    rescue Command::Failed
      nil
    end

    # Extracts path (or the whole tree) at sha into dest.
    def archive(dir, sha, dest, path = nil)
      FileUtils.mkdir_p(dest)
      tarfile = "#{dest}.tar"
      treeish = path ? "#{sha}:#{path}" : sha
      run('-C', dir, 'archive', '--format=tar', '-o', tarfile, treeish)
      Command.run([@config['tar'], '-xf', tarfile, '-C', dest, '--no-same-owner'])
      dest
    ensure
      FileUtils.rm_f(tarfile) if tarfile
    end

    private

    def ensure_mirror_fetched(url)
      dir = mirror_path(url)
      FileUtils.mkdir_p(File.dirname(dir))
      run('init', '--bare', '--quiet', dir) unless File.directory?(dir)
      git(url, '-C', dir, 'fetch', '--prune', '--quiet', '--no-tags', url,
          '+refs/heads/*:refs/heads/*', '+refs/tags/*:refs/tags/*')
      dir
    end

    def commit?(dir, sha)
      run('-C', dir, 'cat-file', '-e', "#{sha}^{commit}")
      true
    rescue Command::Failed
      false
    end

    def git(url, *args)
      Command.run([@config['git'], *args], env: env_for(url), timeout: @config['git_timeout'])
    end

    def run(*args)
      Command.run([@config['git'], *args], env: { 'GIT_TERMINAL_PROMPT' => '0' }, timeout: @config['git_timeout'])
    end
  end

  # Forge API access: latest versions, release checksums, and downloads.
  class Forge
    def initialize(config, state)
      @config = config
      @state = state
      @latest = {}
      token_file = config['forge_token_file']
      @token = File.read(token_file).strip if token_file && File.readable?(token_file)
    end

    def self.api_base(url)
      url = url.to_s.chomp('/')
      return 'https://forgeapi.puppet.com' if url.empty?

      url = "https://#{url}" unless url.include?('://')
      url.sub(%r{://forge\.puppet(labs)?\.com}, '://forgeapi.puppet.com')
    end

    def latest_version(base, slug)
      @latest[[base, slug]] ||= get_json(base, "/v3/modules/#{slug}?exclude_fields=readme+changelog+license+reference")
                                .dig('current_release', 'version') or raise Error, "no current release for #{slug}"
    end

    # Release details never change once published, so they are kept in state.
    def release(base, slug, version)
      key = "#{base} #{slug}-#{version}"
      @state.forge[key] ||= begin
        r = get_json(base, "/v3/releases/#{slug}-#{version}?exclude_fields=readme+changelog+license+reference")
        { 'file_uri' => r['file_uri'], 'sha256' => r['file_sha256'], 'md5' => r['file_md5'] }
      end
    end

    # Downloads and unpacks a release into the cache, verifying its checksum.
    # Returns the module directory.
    def fetch(base, slug, version)
      rel = release(base, slug, version)
      dest = File.join(@config['cache_dir'], 'forge', "#{slug}-#{version}")
      return dest if File.exist?(File.join(dest, '.seamstress_complete'))

      FileUtils.rm_rf(dest)
      FileUtils.mkdir_p(File.dirname(dest))
      tarball = "#{dest}.tar.gz"
      body = get(base, rel['file_uri'])
      verify!(body, rel, slug, version)
      File.binwrite(tarball, body)
      unpack = "#{dest}.unpack"
      FileUtils.rm_rf(unpack)
      FileUtils.mkdir_p(unpack)
      Command.run([@config['tar'], '-xzf', tarball, '-C', unpack, '--no-same-owner'])
      entries = Dir.children(unpack)
      top = entries.size == 1 && File.directory?(File.join(unpack, entries.first)) ? File.join(unpack, entries.first) : unpack
      File.rename(top, dest)
      FileUtils.touch(File.join(dest, '.seamstress_complete'))
      dest
    ensure
      FileUtils.rm_f(tarball) if tarball
      FileUtils.rm_rf(unpack) if unpack
    end

    private

    def verify!(body, rel, slug, version)
      if rel['sha256']
        return if Seamstress.sha256(body) == rel['sha256']
      elsif rel['md5']
        return if Digest::MD5.hexdigest(body) == rel['md5']
      else
        return
      end
      raise Error, "checksum mismatch for #{slug}-#{version}"
    end

    def get_json(base, path)
      JSON.parse(get(base, path))
    end

    def get(base, path, limit = 5)
      uri = URI.join("#{base}/", path.sub(%r{\A/}, ''))
      limit.times do
        req = Net::HTTP::Get.new(uri)
        req['User-Agent'] = "seamstress/#{VERSION}"
        req['Authorization'] = "Bearer #{@token}" if @token && uri.host == URI(base).host
        res = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == 'https',
                                                  open_timeout: 30, read_timeout: 120) { |h| h.request(req) }
        case res
        when Net::HTTPSuccess then return res.body
        when Net::HTTPRedirection then uri = URI.join(uri.to_s, res['location'])
        else raise Error, "GET #{Seamstress.redact(uri)} returned #{res.code}"
        end
      end
      raise Error, "too many redirects fetching #{Seamstress.redact(uri)}"
    end
  end

  # What an environment build needs: provenance, one entry per module, and a
  # fingerprint over every input that affects the output.
  # hiera is nil, or a callable that returns the environment's Hiera index.
  EnvPlan = Struct.new(:name, :provenance, :modules, :fingerprint, :hiera, keyword_init: true)

  # One module to document. prepare is called with a scratch directory and
  # returns the path to the module's source. cache_key, when known before the
  # build, identifies the documented output; when nil the builder hashes the
  # prepared source instead.
  ModPlan = Struct.new(:name, :kind, :source, :ref, :sha, :version, :cache_key, :prepare, :error,
                       keyword_init: true) do
    def to_h_public
      { 'name' => name, 'kind' => kind, 'source' => source, 'ref' => ref, 'sha' => sha, 'version' => version }
    end
  end

  # Common helpers for both sources.
  module SourceHelpers
    # What the Hiera page is configured with, as Hiera.index takes it.
    def hiera_settings
      { samples: @config['hiera_samples'], values: @config['hiera_values'], limit: @config['hiera_values_limit'] }
    end

    # hiera is what the Hiera page depends on, and nil when the page is off,
    # so turning it on, or changing its samples or data, makes a new build.
    def fingerprint(provenance_key, modules, hiera = nil)
      inputs = {
        'generator' => [VERSION, Seamstress.strings_version, Seamstress.generator_digest],
        'provenance' => provenance_key,
        'modules' => modules.map { |m| [m.name, m.kind, m.source, m.ref, m.sha, m.version, m.cache_key, m.error&.message] }
      }
      inputs['hiera'] = hiera if hiera
      Seamstress.sha256(JSON.generate(inputs))
    end

    def metadata_version(dir)
      JSON.parse(File.read(File.join(dir, 'metadata.json')))['version']
    rescue StandardError
      nil
    end

    def module_error(mod_name, phase, err)
      Log.warn("#{mod_name}: #{Seamstress.redact(err.message)}")
      ModuleError.new(phase, Seamstress.redact(err.message))
    end
  end

  # Git mode: environments are branches of the control repo.
  class GitSource
    include SourceHelpers

    def initialize(config, git, forge)
      @config = config
      @git = git
      @forge = forge
    end

    def url = @config['control_repo']

    # { env name => [branch, sha] } for every selected branch.
    def environments
      heads = @git.ls_remote(url).select { |ref, _| ref.start_with?('refs/heads/') }
      by_env = heads.to_h do |ref, sha|
        branch = ref.delete_prefix('refs/heads/')
        [Environments.name_for(branch), [branch, sha]]
      end
      Environments.select(by_env.keys, @config['environments'], @config['exclude_environments'])
                  .to_h { |e| [e, by_env[e]] }
    end

    # The commit an environment is at, known before planning it.
    def commit_for((_branch, sha)) = sha

    def plan(env, (branch, sha))
      mirror = @git.ensure_commit(url, sha)
      text = @git.show(mirror, sha, 'Puppetfile')
      pf = text ? Puppetfile.parse(text) : Puppetfile.new
      base = Forge.api_base(pf.forge_url || @config['forge_url'])
      modules = local_modules(mirror, sha)
      ctx = { base: base, branch: branch, mirror: mirror, sha: sha, moduledir: pf.moduledir }
      modules += pf.mods.map { |m| plan_module(m, ctx) }
      provenance = {
        'source' => 'git', 'control_repo' => Seamstress.redact(url), 'branch' => branch, 'commit' => sha
      }
      hiera = @config['hiera'] ? -> { hiera_index(env, mirror, sha) } : nil
      EnvPlan.new(name: env, provenance: provenance, modules: modules, hiera: hiera,
                  fingerprint: fingerprint(sha, modules, hiera && [hiera_settings, sha]))
    end

    private

    # hiera.yaml and each datadir it names, taken out of the commit for as
    # long as it takes to read them.
    def hiera_index(env, mirror, sha)
      text = @git.show(mirror, sha, 'hiera.yaml')
      return nil unless text

      dest = File.join(@config['cache_dir'], 'work', "#{env}.hiera")
      FileUtils.rm_rf(dest)
      FileUtils.mkdir_p(dest)
      File.write(File.join(dest, 'hiera.yaml'), text)
      HieraFiles.datadirs(text).each { |dir| @git.archive(mirror, sha, File.join(dest, dir), dir) if @git.tree_id(mirror, sha, dir) }
      Hiera.index(dest, environment: env, **hiera_settings)
    ensure
      FileUtils.rm_rf(dest) if dest
    end

    def local_modules(mirror, sha)
      @config['local_module_dirs'].flat_map do |dir|
        @git.trees(mirror, sha, dir).map do |name, tree|
          path = "#{dir}/#{name}"
          ModPlan.new(name: name, kind: 'control', source: path, ref: sha[0, 12], sha: tree,
                      cache_key: "tree:#{tree}",
                      prepare: ->(work) { @git.archive(mirror, sha, File.join(work, name), path) })
        end
      end
    end

    def plan_module(mod, ctx)
      case mod.type
      when :forge then plan_forge(mod, ctx[:base])
      when :git then plan_git(mod, ctx[:branch])
      when :local then plan_local(mod, ctx[:mirror], ctx[:sha], ctx[:moduledir])
      else
        ModPlan.new(name: mod.name, kind: mod.type.to_s, source: mod.title, ref: mod.declared_ref,
                    error: ModuleError.new('resolve', "#{mod.type} modules are not supported"))
      end
    end

    def plan_forge(mod, base)
      version = mod.version.to_s
      version = @forge.latest_version(base, mod.slug) if %w[latest present].include?(version)
      rel = @forge.release(base, mod.slug, version)
      ModPlan.new(name: mod.name, kind: 'forge', source: mod.slug, ref: mod.declared_ref, version: version,
                  sha: rel['sha256'] || rel['md5'], cache_key: "forge:#{base}:#{mod.slug}:#{version}",
                  prepare: ->(_work) { @forge.fetch(base, mod.slug, version) })
    rescue StandardError => e
      ModPlan.new(name: mod.name, kind: 'forge', source: mod.slug, ref: mod.declared_ref,
                  error: module_error(mod.name, 'resolve', e))
    end

    def plan_git(mod, branch)
      murl = mod.options[:git].to_s
      ref, kind = git_ref(mod, branch, murl)
      sha = if ref.match?(/\A\h{7,39}\z/) && !Git.resolve_ref(@git.ls_remote(murl), ref, kind)
              @git.full_sha(murl, ref)
            else
              Git.resolve_ref(@git.ls_remote(murl), ref, kind)
            end
      raise Error, "ref #{ref} not found" unless sha

      ModPlan.new(name: mod.name, kind: 'git', source: Seamstress.redact(murl), ref: ref, sha: sha,
                  cache_key: "git:#{sha}",
                  prepare: lambda { |work|
                    dir = @git.ensure_commit(murl, sha)
                    @git.archive(dir, sha, File.join(work, mod.name))
                  })
    rescue StandardError => e
      ModPlan.new(name: mod.name, kind: 'git', source: Seamstress.redact(murl), ref: mod.declared_ref,
                  error: module_error(mod.name, 'resolve', e))
    end

    # r10k's precedence, including :control_branch, which tracks the
    # environment's own branch and falls back to default_branch.
    def git_ref(mod, branch, murl)
      o = mod.options
      return [o[:commit].to_s, :ref] if o[:commit]
      return [o[:tag].to_s, :tag] if o[:tag]

      want = o[:branch] || o[:ref]
      if want.to_s == 'control_branch'
        refs = @git.ls_remote(murl)
        return [branch, :branch] if refs["refs/heads/#{branch}"]

        want = o[:default_branch_override] || o[:default_branch]
      end
      want ||= o[:default_branch_override] || o[:default_branch]
      return [want.to_s, o[:branch] ? :branch : :ref] if want

      head = @git.ls_remote(murl)['HEAD']
      [head || 'HEAD', :ref]
    end

    def plan_local(mod, mirror, sha, moduledir)
      path = mod.options[:install_path] ? "#{mod.options[:install_path]}/#{mod.name}" : "#{moduledir}/#{mod.name}"
      tree = @git.tree_id(mirror, sha, path) or raise Error, "#{path} not in the control repo"
      ModPlan.new(name: mod.name, kind: 'control', source: path, ref: sha[0, 12], sha: tree, cache_key: "tree:#{tree}",
                  prepare: ->(work) { @git.archive(mirror, sha, File.join(work, mod.name), path) })
    rescue StandardError => e
      ModPlan.new(name: mod.name, kind: 'control', source: path, ref: 'local', error: module_error(mod.name, 'resolve', e))
    end
  end

  # Directory mode: environments are directories already on disk, under
  # code_dir, or unpacked from a tarball. Nothing is assumed about how they
  # got there.
  class DirectorySource
    include SourceHelpers

    def initialize(config)
      @config = config
    end

    # { env name => root directory }
    def environments
      found = {}
      code_dir = @config['code_dir']
      if code_dir && File.directory?(code_dir)
        Dir.children(code_dir).sort.each do |n|
          path = File.join(code_dir, n)
          next unless File.directory?(path)

          if n.match?(/\A\w+\z/)
            found[n] = path
          else
            Log.warn("skipping #{path}: not a valid environment name")
          end
        end
      elsif code_dir
        raise Error, "code_dir #{code_dir} does not exist"
      end
      @config['tarballs'].each_key { |env| found[env] = :tarball }
      Environments.select(found.keys, @config['environments'], @config['exclude_environments'])
                  .to_h { |e| [e, found[e]] }
    end

    def commit_for(_root) = nil

    def plan(env, root)
      provenance = { 'source' => 'directory' }
      if root == :tarball
        tarball = @config['tarballs'].fetch(env)
        digest = Digest::SHA256.file(tarball).hexdigest
        root = unpack(env, tarball, digest)
        provenance['tarball'] = File.basename(tarball)
        provenance['tarball_sha256'] = digest
      end
      provenance['path'] = root
      deploy = read_deploy(root)
      if deploy
        provenance['commit'] = deploy['signature'] if deploy['signature']
        provenance['deployed_at'] = deploy['finished_at'] if deploy['finished_at']
        provenance['deploy_success'] = deploy['deploy_success'] unless deploy['deploy_success'].nil?
      end
      pf = read_puppetfile(root)
      modules = discover(root, pf, deploy)
      change_key = provenance['tarball_sha256'] ||
                   (deploy && Seamstress.sha256(JSON.generate([deploy['signature'], deploy['module_deploys']]))) ||
                   content_hash(modules)
      provenance['change_detection'] = if provenance['tarball_sha256'] then 'tarball checksum'
                                       elsif deploy then '.r10k-deploy.json'
                                       else 'content hash'
                                       end
      hiera, hiera_key = hiera_for(env, root)
      EnvPlan.new(name: env, provenance: provenance, modules: modules, hiera: hiera,
                  fingerprint: fingerprint(change_key, modules, hiera_key))
    end

    # What makes the Hiera index, and what its content hangs on, or nothing
    # when the page is off.
    def hiera_for(env, root)
      return [nil, nil] unless @config['hiera']

      settings = hiera_settings
      [-> { Hiera.index(root, environment: env, **settings) }, [settings, HieraFiles.digest(root)]]
    end

    # Hashes the content of every module directory: path, mode, and bytes.
    def self.tree_hash(dir)
      d = Digest::SHA256.new
      Dir.glob('**/*', File::FNM_DOTMATCH, base: dir).sort.each do |rel|
        next if rel.split('/').any? { |p| p == '.git' } || rel.end_with?('/.', '/..') || ['.', '..'].include?(rel)

        path = File.join(dir, rel)
        st = File.lstat(path)
        d << rel << "\0" << st.mode.to_s << "\0"
        if st.symlink? then d << File.readlink(path)
        elsif st.file? then d.file(path)
        end
        d << "\0"
      end
      d.hexdigest
    end

    private

    def unpack(env, tarball, digest)
      base = File.join(@config['cache_dir'], 'tarballs')
      dest = File.join(base, "#{env}-#{digest[0, 16]}")
      unless File.exist?(File.join(dest, '.seamstress_complete'))
        FileUtils.rm_rf(dest)
        FileUtils.mkdir_p(dest)
        Command.run([@config['tar'], '-xf', tarball, '-C', dest, '--no-same-owner'], timeout: @config['git_timeout'])
        FileUtils.touch(File.join(dest, '.seamstress_complete'))
      end
      Dir.glob(File.join(base, "#{env}-*")).each { |d| FileUtils.rm_rf(d) unless d == dest }
      env_root(dest)
    end

    # A tarball may hold the environment at its root, or inside one top-level
    # directory. Descend into that directory when it is the only thing there.
    def env_root(dir)
      entries = Dir.children(dir) - ['.seamstress_complete']
      markers = %w[Puppetfile environment.conf modules manifests site-modules site .r10k-deploy.json]
      if !entries.intersect?(markers) && entries.size == 1 && File.directory?(File.join(dir, entries.first))
        File.join(dir, entries.first)
      else
        dir
      end
    end

    def read_deploy(root)
      path = File.join(root, '.r10k-deploy.json')
      return nil unless File.exist?(path)

      JSON.parse(File.read(path))
    rescue JSON::ParserError => e
      Log.warn("#{path}: #{e.message}; using metadata.json instead")
      nil
    end

    def read_puppetfile(root)
      path = File.join(root, 'Puppetfile')
      File.exist?(path) ? Puppetfile.parse(File.read(path), path) : nil
    rescue Error => e
      Log.warn("#{e.message}; module sources will come from metadata.json")
      nil
    end

    def discover(root, puppetfile, deploy)
      declared = (puppetfile&.mods || []).to_h { |m| [m.name, m] }
      deployed = (deploy&.dig('module_deploys') || []).to_h { |m| [m['name'], m] }
      seen = {}
      module_dirs(root, puppetfile).flat_map do |base, default_kind|
        Dir.children(base).sort.filter_map do |name|
          path = File.join(base, name)
          next unless File.directory?(path) && !seen[name]

          seen[name] = true
          describe(name, path, default_kind, declared[name], deployed[name])
        end
      end
    end

    # The directories that hold modules, with the kind to report for each:
    # the control repo's own module directories, then the Puppetfile's.
    def module_dirs(root, puppetfile)
      dirs = @config['local_module_dirs'].map { |d| [d, 'control'] }
      dirs << [puppetfile&.moduledir || 'modules', 'deployed']
      dirs.map { |d, kind| [File.join(root, d), kind] }.select { |d, _| File.directory?(d) }
    end

    def describe(name, path, kind, decl, dep)
      meta_version = metadata_version(path)
      source, kind = if decl&.git? then [Seamstress.redact(decl.options[:git]), 'git']
                     elsif decl&.forge? then [decl.slug, 'forge']
                     elsif kind == 'control' then [path.split('/').last(2).join('/'), 'control']
                     else [metadata_source(path) || 'unknown', kind]
                     end
      ref = (dep&.dig('version') || decl&.declared_ref)&.to_s
      # r10k can record sha null for a module pinned to a commit, when it had
      # nothing to resolve. A full commit ref is its own SHA.
      sha = dep&.dig('sha') || (ref if git_sha?(ref))
      ModPlan.new(name: name, kind: kind, source: source, ref: ref, sha: sha,
                  version: meta_version, prepare: ->(_work) { path })
    end

    def git_sha?(ref)
      ref.is_a?(String) && ref.match?(/\A\h{40}\z/)
    end

    def metadata_source(path)
      JSON.parse(File.read(File.join(path, 'metadata.json')))['source']
    rescue StandardError
      nil
    end

    def content_hash(modules)
      Seamstress.sha256(modules.map { |m| "#{m.name}=#{self.class.tree_hash(m.prepare.call(nil))}" }.join("\n"))
    end
  end

  # Where the documentation for a cache key lives. The layout tag changes
  # whenever what is cached changes, so old entries are never misread.
  CACHE_LAYOUT = 'json-1'

  def self.docs_dir(config, key)
    File.join(config['cache_dir'], 'docs', sha256("#{key}|#{strings_version}|#{CACHE_LAYOUT}")[0, 24])
  end

  def self.strings_version
    @strings_version ||= begin
      Gem::Specification.find_by_name('puppet-strings').version.to_s
    rescue Gem::MissingSpecError
      'unknown'
    end
  end

  # Persistent state: what each environment's live build was made from, its
  # last attempt, and the Forge release checksums already looked up.
  class State
    attr_reader :data

    def self.load(path)
      data = File.exist?(path) ? JSON.parse(File.read(path)) : {}
      new(path, data)
    rescue JSON::ParserError
      Log.warn("#{path} is unreadable; starting with empty state")
      new(path, {})
    end

    def initialize(path, data)
      @path = path
      @data = { 'environments' => {}, 'forge' => {} }.merge(data)
    end

    def environments = @data['environments']
    def forge = @data['forge']
    def env(name) = (environments[name] ||= {})

    def save
      FileUtils.mkdir_p(File.dirname(@path))
      Seamstress.atomic_write(@path, JSON.pretty_generate(@data), mode: 0o640)
    end
  end

  # Builds one environment into a fresh directory.
  class Builder
    def initialize(config, renderer)
      @config = config
      @renderer = renderer
    end

    # Returns [build_dir, manifest]. Module failures are recorded in the
    # manifest; anything that stops the whole environment raises.
    def build(plan, built_at, previous = nil)
      tmp = File.join(@config.builds_dir, ".tmp-#{plan.name}-#{Process.pid}")
      work = File.join(@config['cache_dir'], 'work', plan.name)
      FileUtils.rm_rf([tmp, work])
      FileUtils.mkdir_p([File.join(tmp, 'modules'), work])
      results = plan.modules.map { |mod| build_module(mod, tmp, work) }
      manifest = {
        'environment' => plan.name, 'fingerprint' => plan.fingerprint, 'built_at' => built_at,
        'provenance' => plan.provenance, 'generator' => { 'seamstress' => VERSION, 'puppet_strings' => Seamstress.strings_version },
        'modules' => results
      }
      hiera = write_hiera(plan, tmp)
      manifest['hiera'] = hiera if hiera
      @renderer.environment(tmp, manifest, previous)
      [tmp, manifest]
    rescue StandardError
      FileUtils.rm_rf(tmp) if tmp
      raise
    ensure
      FileUtils.rm_rf(work) if work
    end

    private

    # The Hiera page's index, beside the pages. Returns what the manifest says
    # about it, or nil when the page is off or the environment has no Hiera 5
    # configuration. A hierarchy that cannot be read costs the page, not the
    # build.
    def write_hiera(plan, out)
      index = plan.hiera&.call
      return nil unless index

      File.write(File.join(out, 'hiera.json'), JSON.generate(index))
      Hiera.summary(index)
    rescue StandardError => e
      Log.warn("#{plan.name}: the Hiera page is left out, its data could not be read: #{e.class}: #{Seamstress.redact(e.message)}")
      nil
    end

    def build_module(mod, out, work)
      entry = mod.to_h_public.merge('status' => 'ok')
      raise mod.error if mod.error

      src = prepare(mod, work)
      entry['version'] ||= metadata_version(src)
      key = mod.cache_key || "content:#{DirectorySource.tree_hash(src)}"
      cached = docs_for(key, mod.name, src, work)
      dest = File.join(out, 'modules', mod.name)
      FileUtils.cp_r(cached, dest)
      FileUtils.rm_f(File.join(dest, '.seamstress_complete'))
      entry['cache_key'] = key
      entry['index'] = 'index.html'
      entry
    rescue ModuleError => e
      entry.merge('status' => 'failed', 'phase' => e.phase, 'error' => e.message, 'transient' => e.transient?)
    rescue StandardError => e
      # Anything unexpected stays with this module rather than failing the
      # environment, and is retried next run.
      Log.warn("#{mod.name}: #{e.class}: #{Seamstress.redact(e.message)}")
      entry.merge('status' => 'failed', 'phase' => 'build', 'error' => Seamstress.redact(e.message), 'transient' => true)
    end

    def prepare(mod, work)
      src = mod.prepare.call(work)
      raise ModuleError.new('fetch', "#{src} is missing") unless src && File.directory?(src)

      src
    rescue ModuleError
      raise
    rescue StandardError => e
      Log.warn("#{mod.name}: #{Seamstress.redact(e.message)}")
      raise ModuleError.new('fetch', Seamstress.redact(e.message))
    end

    def metadata_version(dir)
      JSON.parse(File.read(File.join(dir, 'metadata.json')))['version']
    rescue StandardError
      nil
    end

    # Documentation for one module, from the cache or freshly generated:
    # the puppet-strings JSON plus the module's metadata.json and README,
    # which the module page shows. The source is copied first so
    # puppet-strings never writes into it.
    def docs_for(key, name, src, work)
      dir = Seamstress.docs_dir(@config, key)
      return dir if File.exist?(File.join(dir, '.seamstress_complete'))

      copy = File.join(work, "#{name}.strings")
      FileUtils.rm_rf(copy)
      FileUtils.mkdir_p(copy)
      Dir.children(src).each { |c| FileUtils.cp_r(File.join(src, c), copy) unless %w[.git doc .yardoc].include?(c) }
      generate(name, copy)
      staged = "#{dir}.tmp-#{Process.pid}"
      FileUtils.rm_rf([dir, staged])
      FileUtils.mkdir_p(staged)
      FileUtils.mv(File.join(copy, 'strings.json'), staged)
      keep_module_files(copy, staged)
      FileUtils.touch(File.join(staged, '.seamstress_complete'))
      File.rename(staged, dir)
      dir
    ensure
      FileUtils.rm_rf(copy) if copy
      FileUtils.rm_rf(staged) if staged && File.exist?(staged)
    end

    # metadata.json and the first README found, as README.md when it is
    # markdown and README.txt when it is not. Regular files only: a
    # symlink in a module must not pull in something outside it.
    def keep_module_files(src, dest)
      meta = File.join(src, 'metadata.json')
      FileUtils.cp(meta, dest) if File.file?(meta) && !File.symlink?(meta)
      readme = Dir.children(src).sort.find { |f| f.match?(/\AREADME(\.(md|markdown|txt|rdoc))?\z/i) && File.file?(File.join(src, f)) }
      return unless readme && !File.symlink?(File.join(src, readme))

      target = readme.match?(/\.(md|markdown)\z/i) ? 'README.md' : 'README.txt'
      FileUtils.cp(File.join(src, readme), File.join(dest, target))
    end

    def generate(name, dir)
      env = { 'HOME' => ENV.fetch('HOME', dir), 'LANG' => 'C.UTF-8' }
      Command.run([@config['puppet'], 'strings', 'generate', '--format', 'json', '--out', 'strings.json'],
                  env: env, chdir: dir, timeout: @config['module_timeout'])
      raise ModuleError.new('strings', 'puppet strings produced no JSON') unless File.exist?(File.join(dir, 'strings.json'))
    rescue Command::Failed => e
      Log.warn("#{name}: #{e.message}")
      raise ModuleError.new('strings', e.message)
    end
  end

  # Moves finished builds into place and removes what is no longer needed.
  class Publisher
    def initialize(config)
      @config = config
    end

    def publish(env, tmp, fingerprint)
      id = "#{env}-#{fingerprint[0, 12]}"
      id = "#{id}-#{Time.now.to_i}" if File.exist?(File.join(@config.builds_dir, id))
      final = File.join(@config.builds_dir, id)
      File.rename(tmp, final)
      FileUtils.mkdir_p(@config.links_dir)
      link = File.join(@config.links_dir, env)
      tmp_link = File.join(@config.links_dir, ".#{env}.tmp")
      FileUtils.rm_f(tmp_link)
      File.symlink(File.join('..', 'builds', id), tmp_link)
      File.rename(tmp_link, link)
      id
    end

    def live(env)
      link = File.join(@config.links_dir, env)
      File.symlink?(link) ? File.basename(File.readlink(link)) : nil
    end

    def builds_for(env)
      Dir.children(@config.builds_dir).grep(/\A#{Regexp.escape(env)}-\h{12}(-\d+)?\z/)
    rescue Errno::ENOENT
      []
    end

    # Keeps the live build and the newest others, up to keep_builds in all.
    def prune(env)
      live_id = live(env)
      others = (builds_for(env) - [live_id]).sort_by { |b| -File.mtime(File.join(@config.builds_dir, b)).to_f }
      keep = [@config['keep_builds'].to_i - (live_id ? 1 : 0), 0].max
      others.drop(keep).each { |b| remove_build(b) }
    end

    # Removes environments that no longer exist at the source. Only called
    # when the source listed its environments successfully.
    def prune_dropped(current)
      return unless File.directory?(@config.links_dir)

      Dir.children(@config.links_dir).each do |n|
        next if n.start_with?('.') || current.include?(n)

        Log.info("#{n}: environment is gone, removing it")
        builds_for(n).each { |b| remove_build(b) }
        FileUtils.rm_f(File.join(@config.links_dir, n))
      end
      Dir.glob(File.join(@config.builds_dir, '.tmp-*')).each { |d| FileUtils.rm_rf(d) }
    end

    # Every documentation cache key a remaining build still points at.
    def referenced_cache_keys
      Dir.glob(File.join(@config.builds_dir, '*', 'build.json')).flat_map do |f|
        JSON.parse(File.read(f))['modules'].filter_map { |m| m['cache_key'] }
      rescue JSON::ParserError
        []
      end
    end

    private

    def remove_build(id)
      Log.info("pruning build #{id}")
      FileUtils.rm_rf(File.join(@config.builds_dir, id))
    end
  end

  # One polling run across every environment.
  class App
    attr_reader :config, :state

    def initialize(config, force: false, only: nil, git: nil, forge: nil, renderer: nil)
      @config = config
      @force = force
      @only = only
      @state = State.load(config['state_file'])
      @git = git || Git.new(config)
      @forge = forge || Forge.new(config, @state)
      @renderer = renderer || Renderer.new(config)
      @builder = Builder.new(config, @renderer)
      @publisher = Publisher.new(config)
    end

    def source
      @source ||= config['source'] == 'git' ? GitSource.new(config, @git, @forge) : DirectorySource.new(config)
    end

    # Returns the process exit status: 0 when every environment is live and
    # current, 1 when anything failed at the environment level.
    def run
      started = Time.now.utc
      FileUtils.mkdir_p([config.builds_dir, config.links_dir, config['cache_dir']])
      install_assets
      ok = true
      begin
        envs = source.environments
      rescue StandardError => e
        Log.error("cannot list environments: #{Seamstress.redact(e.message)}")
        state.data['last_attempt'] = started.iso8601
        finish(started, false)
        return 1
      end
      Log.info("#{envs.size} environment(s): #{envs.keys.sort.join(', ')}")
      envs.each do |env, ref|
        next if @only && env != @only

        ok = false unless process(env, ref, started)
      end
      unless @only
        state.environments.keep_if { |name, _| envs.key?(name) }
        @publisher.prune_dropped(envs.keys)
        prune_cache
      end
      finish(started, ok)
      ok ? 0 : 1
    end

    private

    def process(env, ref, started)
      st = state.env(env)
      plan = source.plan(env, ref)
      unless rebuild?(st, plan)
        Log.debug("#{env}: unchanged")
        return true
      end
      Log.info("#{env}: building #{plan.fingerprint[0, 12]} (#{plan.modules.size} modules)")
      tmp, manifest = @builder.build(plan, started.iso8601, previous_manifest(env))
      id = @publisher.publish(env, tmp, plan.fingerprint)
      failed = record_success(st, plan, manifest, id, started)
      @publisher.prune(env)
      Log.info("#{env}: live as #{id}#{", #{failed.size} module(s) failed" unless failed.empty?}")
      true
    rescue StandardError => e
      msg = Seamstress.redact(e.message)
      Log.error("#{env}: build failed, the previous build stays live: #{msg}")
      Log.debug(e.backtrace.join("\n"))
      st['last_attempt'] = { 'at' => started.iso8601, 'status' => 'failed', 'error' => msg,
                             'commit' => plan&.provenance&.dig('commit') || source.commit_for(ref) }
      false
    end

    # The live build's manifest, for what changed since. Unreadable is the
    # same as none.
    def previous_manifest(env)
      path = File.join(config.links_dir, env, 'build.json')
      File.exist?(path) ? JSON.parse(File.read(path)) : nil
    rescue JSON::ParserError
      nil
    end

    def record_success(env_state, plan, manifest, id, started)
      failed = manifest['modules'].select { |m| m['status'] == 'failed' }
      env_state.replace(
        'fingerprint' => plan.fingerprint, 'build' => id, 'built_at' => started.iso8601,
        'provenance' => plan.provenance, 'modules' => manifest['modules'].size,
        'failed_modules' => failed.map { |m| m['name'] }, 'transient' => failed.any? { |m| m['transient'] },
        'last_attempt' => { 'at' => started.iso8601, 'status' => 'ok' }
      )
      failed
    end

    def rebuild?(env_state, plan)
      return true if @force
      return true unless env_state['build'] && @publisher.live(plan.name) == env_state['build']
      return true if env_state['fingerprint'] != plan.fingerprint
      return true if env_state['transient']
      return true if env_state.dig('last_attempt', 'status') == 'failed'

      false
    end

    def install_assets
      dest = File.join(config['docroot'], 'assets')
      FileUtils.mkdir_p(dest)
      Dir.children(config.assets_dir).each do |f|
        content = File.binread(File.join(config.assets_dir, f))
        target = File.join(dest, f)
        Seamstress.atomic_write(target, content) unless File.exist?(target) && File.binread(target) == content
      end
    end

    def prune_cache
      keep = @publisher.referenced_cache_keys.map { |k| File.basename(Seamstress.docs_dir(config, k)) }
      docs = File.join(config['cache_dir'], 'docs')
      Dir.children(docs).each { |d| FileUtils.rm_rf(File.join(docs, d)) unless keep.include?(d) } if File.directory?(docs)
    end

    def finish(started, success)
      state.data['last_attempt'] = started.iso8601
      state.data['last_success'] = started.iso8601 if success
      state.save
      status = public_status
      Seamstress.atomic_write(File.join(config['docroot'], 'status.json'), JSON.pretty_generate(status))
      @renderer.index(status)
      write_metrics(started)
    end

    def public_status
      envs = state.environments.to_h do |name, st|
        [name, {
          'build' => st['build'], 'built_at' => st['built_at'], 'provenance' => st['provenance'],
          'modules' => st['modules'], 'failed_modules' => st['failed_modules'] || [],
          'last_attempt' => st['last_attempt']
        }]
      end
      {
        'generated_at' => Time.now.utc.iso8601, 'last_success' => state.data['last_success'],
        'last_attempt' => state.data['last_attempt'], 'source' => config['source'],
        'version' => VERSION, 'environments' => envs
      }
    end

    def write_metrics(started)
      path = config['metrics_file']
      return unless path

      envs = state.environments.values
      failed_modules = envs.sum { |e| (e['failed_modules'] || []).size }
      failed_envs = envs.count { |e| e.dig('last_attempt', 'status') == 'failed' }
      success = state.data['last_success'] ? Time.parse(state.data['last_success']).to_i : 0
      body = <<~PROM
        # HELP seamstress_last_success_timestamp_seconds Start time of the last run in which every environment built or was current.
        # TYPE seamstress_last_success_timestamp_seconds gauge
        seamstress_last_success_timestamp_seconds #{success}
        # HELP seamstress_last_attempt_timestamp_seconds Start time of the last run.
        # TYPE seamstress_last_attempt_timestamp_seconds gauge
        seamstress_last_attempt_timestamp_seconds #{started.to_i}
        # HELP seamstress_failed_modules Modules whose documentation failed in the live builds.
        # TYPE seamstress_failed_modules gauge
        seamstress_failed_modules #{failed_modules}
        # HELP seamstress_failed_environments Environments whose last build failed.
        # TYPE seamstress_failed_environments gauge
        seamstress_failed_environments #{failed_envs}
      PROM
      begin
        Seamstress.atomic_write(path, body)
      rescue Errno::EACCES, Errno::EROFS, Errno::EPERM
        File.write(path, body)
      end
    rescue StandardError => e
      Log.warn("cannot write #{path}: #{e.message}")
    end
  end

  def self.main(argv)
    opts = { config: '/etc/seamstress/config.json' }
    OptionParser.new do |o|
      o.banner = 'Usage: seamstress.rb [options]'
      o.on('-c', '--config PATH', 'Config file') { |v| opts[:config] = v }
      o.on('-f', '--force', 'Rebuild every environment') { opts[:force] = true }
      o.on('-e', '--environment NAME', 'Only this environment') { |v| opts[:only] = v }
      o.on('-d', '--debug', 'Debug logging') { Log.debug = true }
      o.on('-v', '--version', 'Print the version') do
        puts VERSION
        return 0
      end
    end.parse!(argv)
    config = Config.load(opts[:config])
    File.umask(0o022)
    lock_path = File.join(File.dirname(config['state_file']), '.seamstress.lock')
    FileUtils.mkdir_p(File.dirname(lock_path))
    File.open(lock_path, File::RDWR | File::CREAT, 0o640) do |lock|
      unless lock.flock(File::LOCK_EX | File::LOCK_NB)
        Log.info('another run holds the lock; exiting')
        return 0
      end
      App.new(config, force: opts[:force], only: opts[:only]).run
    end
  rescue Error, OptionParser::ParseError, JSON::ParserError, Errno::ENOENT => e
    Log.error(Seamstress.redact(e.message))
    2
  end
end

exit(Seamstress.main(ARGV)) if $PROGRAM_NAME == __FILE__
