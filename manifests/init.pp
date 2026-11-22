# @summary
#   Builds and serves a puppet-strings documentation site for every module in
#   every environment of a Puppet control repo.
#
# The site is rebuilt by a systemd timer. Each run checks whether anything
# moved and rebuilds only the environments that changed. Every module gets its
# own puppet-strings run, so one module that fails to document does not take
# the rest down, and a build that fails outright leaves the previous one live.
#
# Two sources are supported. `git` polls the control repo with `git ls-remote`
# and resolves each Puppetfile itself, so it needs read access to every
# repository the Puppetfile names. `directory` reads environments that are
# already on disk, or a tarball per environment, and needs no git access.
#
# @param source
#   Where environments come from: `git` (the control repo) or `directory`
#   (code already deployed on disk).
# @param control_repo
#   Git URL of the control repo. Required when `source` is `git`.
# @param code_dir
#   Directory holding one subdirectory per environment, such as
#   `/etc/puppetlabs/code/environments`. Used when `source` is `directory`.
# @param tarballs
#   Environment name to the path of a tarball holding that environment. Each is
#   unpacked into the cache before building, and its checksum decides whether
#   the environment changed. Used when `source` is `directory`.
# @param environments
#   Environments to build. Empty means every branch or directory found.
# @param exclude_environments
#   Regular expressions; an environment whose name matches any of them is
#   skipped. Applied after `environments`.
# @param local_module_dirs
#   Directories inside each environment that hold modules kept in the control
#   repo itself, such as roles and profiles.
# @param deploy_keys
#   Read-only SSH keys for git, keyed by a URL or a shell glob that the
#   repository URL must match, for example `git@github.com:example/*`. The most
#   specific match wins, so per-repository deploy keys on one host work.
# @param ssh_known_hosts
#   Lines for the service user's `known_hosts` file. Strongly recommended with
#   `strict_host_key_checking` set to `yes`.
# @param strict_host_key_checking
#   SSH host key policy for git over SSH. `accept-new` trusts a host the first
#   time it is seen; `yes` only trusts hosts in `ssh_known_hosts`.
# @param forge_url
#   Forge API used for Forge modules when a Puppetfile names none.
# @param forge_token
#   Optional Forge API key, for modules that need authentication to download.
# @param docroot
#   Directory the site is written to and served from.
# @param base_dir
#   Home of the service user, holding state, keys, and the build cache.
# @param install_dir
#   Where the build script and its templates and assets are installed.
# @param config_dir
#   Where the build script's configuration file is written.
# @param user
#   System user the build runs as. Created with no login shell.
# @param group
#   Primary group of the service user.
# @param supplementary_groups
#   Extra groups for the service, for example one that can read `code_dir`.
# @param manage_user
#   Whether to create the user and group.
# @param poll_interval
#   How long after the last run starts before the next one, as a systemd time
#   span such as `5min`.
# @param strings_version
#   Version of the puppet-strings gem installed into Puppet's Ruby.
# @param manage_git
#   Whether to install the git package.
# @param ruby
#   Ruby that runs the build script. Puppet's own Ruby, which also holds
#   puppet-strings.
# @param puppet
#   The puppet executable used to run `puppet strings`.
# @param keep_builds
#   Builds kept per environment, including the live one.
# @param module_timeout
#   Seconds one module's documentation may take before it is abandoned.
# @param metrics_file
#   Prometheus textfile collector file for build metrics. Off when undef. Its
#   directory must exist and be writable by `user`.
# @param site_title
#   Name shown at the top of every page.
# @param timer_enable
#   Whether the timer is enabled and running.
# @param manage_nginx
#   Whether to install nginx and serve `docroot` over HTTPS.
# @param port
#   Port nginx listens on.
# @param server_name
#   Name nginx answers to.
# @param tls_cert
#   Certificate nginx presents, PEM. Copied into nginx's configuration
#   directory. Defaults to the node's Puppet agent certificate.
# @param tls_key
#   Private key for `tls_cert`, PEM. Copied with mode 0600. Defaults to the
#   node's Puppet agent key.
#
# @example Build every branch of a control repo
#   class { 'strings_site':
#     control_repo => 'git@git.example.com:puppet/control-repo.git',
#     deploy_keys  => {
#       'git@git.example.com:puppet/*' => Sensitive(lookup('strings_site_deploy_key')),
#     },
#   }
#
# @example Only production and development, from code already deployed on disk
#   class { 'strings_site':
#     source       => 'directory',
#     code_dir     => '/srv/puppet/environments',
#     environments => ['production', 'development'],
#   }
#
# @example Behind a load balancer that terminates TLS
#   class { 'strings_site':
#     control_repo => 'https://git.example.com/puppet/control-repo.git',
#     manage_nginx => false,
#   }
class strings_site (
  Enum['git', 'directory'] $source = 'git',
  Optional[String[1]] $control_repo = undef,
  Optional[Stdlib::Absolutepath] $code_dir = undef,
  Hash[Pattern[/\A\w+\z/], Stdlib::Absolutepath] $tarballs = {},
  Array[String[1]] $environments = [],
  Array[String[1]] $exclude_environments = [],
  Array[String[1]] $local_module_dirs = ['site-modules', 'site'],
  Hash[String[1], Sensitive[String[1]]] $deploy_keys = {},
  Array[String[1]] $ssh_known_hosts = [],
  Enum['yes', 'accept-new'] $strict_host_key_checking = 'accept-new',
  Stdlib::HTTPUrl $forge_url = 'https://forgeapi.puppet.com',
  Optional[Sensitive[String[1]]] $forge_token = undef,
  Stdlib::Absolutepath $docroot = '/var/www/strings_site',
  Stdlib::Absolutepath $base_dir = '/var/lib/strings_site',
  Stdlib::Absolutepath $install_dir = '/opt/strings_site',
  Stdlib::Absolutepath $config_dir = '/etc/strings_site',
  String[1] $user = 'strings',
  String[1] $group = 'strings',
  Array[String[1]] $supplementary_groups = [],
  Boolean $manage_user = true,
  String[1] $poll_interval = '5min',
  String[1] $strings_version = '5.1.0',
  Boolean $manage_git = true,
  Stdlib::Absolutepath $ruby = '/opt/puppetlabs/puppet/bin/ruby',
  Stdlib::Absolutepath $puppet = '/opt/puppetlabs/bin/puppet',
  Integer[1] $keep_builds = 2,
  Integer[1] $module_timeout = 600,
  Optional[Stdlib::Absolutepath] $metrics_file = undef,
  String[1] $site_title = 'Puppet module reference',
  Boolean $timer_enable = true,
  Boolean $manage_nginx = true,
  Stdlib::Port $port = 443,
  Stdlib::Host $server_name = $facts['networking']['fqdn'],
  Stdlib::Absolutepath $tls_cert = "/etc/puppetlabs/puppet/ssl/certs/${trusted['certname']}.pem",
  Stdlib::Absolutepath $tls_key = "/etc/puppetlabs/puppet/ssl/private_keys/${trusted['certname']}.pem",
) {
  if $source == 'git' and $control_repo =~ Undef {
    fail('strings_site: control_repo is required when source is git')
  }
  if $source == 'directory' and $code_dir =~ Undef and $tarballs.empty {
    fail('strings_site: source directory needs code_dir, tarballs, or both')
  }

  contain strings_site::install
  contain strings_site::config
  contain strings_site::service

  Class['strings_site::install']
  -> Class['strings_site::config']
  ~> Class['strings_site::service']

  if $manage_nginx {
    contain strings_site::nginx
    Class['strings_site::config'] -> Class['strings_site::nginx']
  }
}
