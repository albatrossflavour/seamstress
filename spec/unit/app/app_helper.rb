# frozen_string_literal: true

# Shared setup for the build script's unit tests. These run the real script
# against throwaway git repos and directories, with a stand-in for
# `puppet strings` so no Puppet or network access is needed.

require 'fileutils'
require 'json'
require 'stringio'
require 'tmpdir'
require_relative '../../../files/app/seamstress'

module AppHelper
  FAKE_PUPPET = <<~SH
    #!/bin/sh
    # Stands in for `puppet strings generate`. A module containing a file
    # called FAIL_STRINGS fails, the way a module with broken code would.
    if [ -f FAIL_STRINGS ]; then
      echo "Error: could not parse manifests/init.pp" >&2
      exit 1
    fi
    name=$(basename "$(pwd)" .strings)
    if [ "$3" = "--format" ]; then
      printf '{"puppet_classes":[{"name":"%s","docstring":{"text":"The %s class.","tags":[{"tag_name":"summary","text":"Summary of %s."}]}}],"puppet_plans":[{"name":"%s::deploy","docstring":{"text":"Deploys."}}]}' "$name" "$name" "$name" "$name" > "$6"
    else
      mkdir -p doc/puppet_classes doc/puppet_plans
      printf '<html><head><title>%s</title></head><body>%s</body></html>' "$name" "$name" > doc/index.html
      printf '<html><head></head><body>%s</body></html>' "$name" > "doc/puppet_classes/$name.html"
      printf '<html><head></head><body>plan</body></html>' > "doc/puppet_plans/${name}_3A_3Adeploy.html"
      printf '<html><head></head><body>list</body></html>' > doc/class_list.html
    fi
  SH

  def self.included(base)
    base.class_eval do
      around do |example|
        Dir.mktmpdir('seamstress_spec') do |dir|
          @tmp = dir
          Seamstress::Log.io = StringIO.new
          example.run
        ensure
          Seamstress::Log.io = $stderr
        end
      end
    end
  end

  attr_reader :tmp

  def fake_puppet
    path = File.join(tmp, 'bin', 'puppet')
    unless File.exist?(path)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, FAKE_PUPPET)
      File.chmod(0o755, path)
    end
    path
  end

  def log
    Seamstress::Log.io.string
  end

  def sh(*cmd, chdir: nil)
    out, err, status = Open3.capture3({ 'GIT_CONFIG_GLOBAL' => '/dev/null' }, *cmd, chdir: chdir || tmp)
    raise "#{cmd.join(' ')} failed: #{err}" unless status.success?

    out
  end

  def git(dir, *)
    sh('git', '-c', 'user.name=Spec', '-c', 'user.email=spec@example.com', '-c', 'init.defaultBranch=production',
       *, chdir: dir)
  end

  def write(path, content)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, content)
  end

  def manifest(mod, klass = mod)
    "# @summary #{klass}\nclass #{klass} {}\n"
  end

  # A control repo with a profile module and the given Puppetfile.
  def control_repo(puppetfile = '')
    dir = File.join(tmp, 'control')
    FileUtils.mkdir_p(dir)
    git(dir, 'init', '-q')
    write(File.join(dir, 'Puppetfile'), puppetfile)
    write(File.join(dir, 'site-modules/profile/manifests/init.pp'), manifest('profile'))
    commit(dir, 'initial')
    dir
  end

  def commit(dir, message)
    git(dir, 'add', '-A')
    git(dir, 'commit', '-q', '--allow-empty', '-m', message)
    git(dir, 'rev-parse', 'HEAD').strip
  end

  def module_repo(name)
    dir = File.join(tmp, "mod-#{name}")
    FileUtils.mkdir_p(dir)
    git(dir, 'init', '-q', '-b', 'main')
    write(File.join(dir, 'manifests/init.pp'), manifest(name))
    write(File.join(dir, 'metadata.json'), JSON.generate('name' => "example-#{name}", 'version' => '1.2.3'))
    commit(dir, 'initial')
    dir
  end

  def config(overrides = {})
    Seamstress::Config.new({
      'docroot' => File.join(tmp, 'www'),
      'cache_dir' => File.join(tmp, 'cache'),
      'state_file' => File.join(tmp, 'state', 'state.json'),
      'puppet' => fake_puppet,
      'metrics_file' => File.join(tmp, 'metrics.prom')
    }.merge(overrides))
  end

  def run_app(cfg, **)
    Seamstress::App.new(cfg, **).run
  end

  def live(env)
    link = File.join(tmp, 'www', 'environments', env)
    File.symlink?(link) ? File.basename(File.readlink(link)) : nil
  end

  def builds
    Dir.children(File.join(tmp, 'www', 'builds')).sort
  end

  def build_json(env)
    JSON.parse(File.read(File.join(tmp, 'www', 'environments', env, 'build.json')))
  end

  def status
    JSON.parse(File.read(File.join(tmp, 'www', 'status.json')))
  end

  def metrics
    File.read(File.join(tmp, 'metrics.prom')).lines.reject { |l| l.start_with?('#') }
        .to_h { |l| l.split.then { |k, v| [k, v.to_i] } }
  end
end
