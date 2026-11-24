# @summary
#   Builds and serves a documentation site for a Puppet control repo: every
#   module in every environment, and, optionally, its Hiera data.
#
# The site is rebuilt by a systemd timer. Each run checks whether anything
# moved and rebuilds only the environments that changed. Every module gets its
# own puppet-strings run, so one module that fails to document does not take
# the rest down, and a build that fails outright leaves the previous one live.
#
# The site is rendered from each module's puppet-strings JSON, so every page
# shares one design: an environment dashboard with documentation coverage and
# what changed since the last build, a page per module and per class, defined
# type, resource type, provider, function, task, plan, and data type, a
# command palette that searches all of them, and a comparison of any two
# environments. It is static and loads nothing from outside the site.
#
# `hiera` adds a second section, the Hiera Explorer: an environment's
# hierarchy level by level for a sample node, the keys each level sets, and
# what wins. `auth` puts the whole site behind sign-in, through an OpenID
# Connect provider or HTTP basic auth.
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
#   Lines for the service user's `known_hosts` file. Needed for every host
#   when `strict_host_key_checking` is `yes`, or its fetches fail.
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
# @param usershell
#   Login shell for the service users, the build's and oauth2-proxy's. Set it
#   to `/sbin/nologin` where a hardening module, such as SCE's CIS benchmark,
#   enforces that path, or each corrects the other on every run.
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
#   Name in each page's title, as the browser tab shows it. The pages
#   themselves carry seamstress's own name and mark.
# @param hiera
#   Add a Hiera Explorer to each environment: its hierarchy, level by level, and
#   what a sample node would get from each. The page publishes the values in
#   the environment's data files to anyone who can read the site, so it is off
#   by default, and belongs behind `auth`. Encrypted (eyaml) values are left
#   out when the site is built and nothing is decrypted. The environment's
#   `hiera.yaml` and data have to be in what the site is built from, so a
#   tarball that leaves the data out has no page.
# @param hiera_samples
#   Named sample nodes for the Hiera Explorer, each a hash of the hierarchy's
#   variables, as written in `hiera.yaml`, to the value the node has. The
#   first is shown when the page opens. Without any, the reader fills the
#   variables in from the values the data files imply.
# @param hiera_values
#   More values to offer for the Hiera Explorer's variables, as a hash of
#   variable, as written in `hiera.yaml`, to an array of values. The fields
#   already offer what the data files and the samples imply. This is for
#   values the files cannot imply, such as the certnames and roles that exist
#   in your estate, which a profile can take from PuppetDB when it declares
#   the class. They are published on the page with everything else.
# @param hiera_values_limit
#   The most values from `hiera_values` to offer for one variable. With more,
#   the first this many in order are kept and the page says so. It keeps a
#   large estate's certnames from swelling every environment's index.
# @param timer_enable
#   Whether the timer is enabled and running.
# @param manage_nginx
#   Whether to install nginx and serve `docroot` over HTTPS.
# @param port
#   Port nginx listens on.
# @param server_name
#   Name nginx answers to.
# @param tls_cert
#   Certificate nginx presents: the path of a PEM file on the node, or the PEM
#   itself, with any intermediates after the leaf. Copied into nginx's
#   configuration directory. Defaults to the node's Puppet agent certificate.
# @param tls_key
#   Private key for `tls_cert`: the path of a PEM file on the node, or the PEM
#   itself as Sensitive or Deferred. Written with mode 0600. Use Deferred (for
#   example from node_encrypt or a Vault lookup) to keep the key out of the
#   catalogue, which records a Sensitive class parameter in plaintext.
#   Defaults to the node's Puppet agent key.
# @param auth
#   Who may read the site. `none` leaves it open to anyone who can reach it.
#   `oidc` sends readers to an OpenID Connect identity provider through
#   oauth2-proxy, which the module installs and runs on the node. `basic` asks
#   for a username and password from `basic_auth_users`. Both are enforced by
#   nginx, so both need `manage_nginx`.
# @param basic_auth_users
#   Users allowed to read the site when `auth` is `basic`, as username =>
#   password hash. Hashes only, so no password is ever in the catalogue:
#   sha512-crypt (`openssl passwd -6`), sha256-crypt, yescrypt, bcrypt, or apr1
#   (`htpasswd -m`).
# @param basic_auth_realm
#   The realm the browser shows in its sign-in prompt.
# @param oidc_issuer_url
#   Issuer URL of the identity provider, the address its
#   `/.well-known/openid-configuration` sits under. Required when `auth` is
#   `oidc`.
# @param oidc_client_id
#   Client ID registered for the site at the identity provider. Required when
#   `auth` is `oidc`.
# @param oidc_client_secret
#   Client secret for `oidc_client_id`, as Sensitive or Deferred, with no
#   trailing newline. Required when `auth` is `oidc`. The catalogue records a
#   Sensitive class parameter in plaintext, so use Deferred (for example from
#   node_encrypt or a Vault lookup) to keep the secret out of it.
# @param oidc_allowed_groups
#   Groups, as named in `oidc_groups_claim`, whose members may read the site.
#   Empty allows anyone the identity provider signs in.
# @param oidc_email_domains
#   Email domains allowed to sign in. `*` allows any.
# @param oidc_allow_unverified_email
#   Let in a user whose token says `email_verified` is false. oauth2-proxy
#   refuses them with a 403 otherwise. Some providers send false for every
#   user unless told otherwise (authentik's default email scope does), so set
#   this when access is decided by `oidc_allowed_groups` and not by the email
#   address, or have the provider assert the address instead.
# @param oidc_scope
#   Scopes requested from the identity provider. Add `groups` if the provider
#   only puts group membership in the token when asked.
# @param oidc_groups_claim
#   Token claim holding the user's groups.
# @param oidc_provider_ca_file
#   CA bundle on the node that oauth2-proxy trusts for the identity provider,
#   for one with a certificate from a private CA. Replaces the system trust
#   store rather than adding to it.
# @param oauth2_proxy_version
#   Version of oauth2-proxy downloaded and run. A new version installs beside
#   the old one.
# @param oauth2_proxy_checksums
#   SHA-256 of the release tarball for each architecture, checked before the
#   tarball is unpacked. Set it with `oauth2_proxy_version`.
# @param oauth2_proxy_download_base
#   Where release tarballs are fetched from, as
#   `<base>/v<version>/oauth2-proxy-v<version>.linux-<arch>.tar.gz`. Point it
#   at a mirror for a node with no internet access.
# @param oauth2_proxy_port
#   Port oauth2-proxy listens on, on 127.0.0.1 only.
#
# @example Build every branch of a control repo
#   class { 'seamstress':
#     control_repo => 'git@git.example.com:puppet/control-repo.git',
#     deploy_keys  => {
#       'git@git.example.com:puppet/*' => Sensitive(lookup('seamstress_deploy_key')),
#     },
#   }
#
# @example Only production and development, from code already deployed on disk
#   class { 'seamstress':
#     source       => 'directory',
#     code_dir     => '/srv/puppet/environments',
#     environments => ['production', 'development'],
#   }
#
# @example Sign in through an OpenID Connect identity provider
#   class { 'seamstress':
#     control_repo        => 'git@git.example.com:puppet/control-repo.git',
#     auth                => 'oidc',
#     oidc_issuer_url     => 'https://login.example.com/realms/staff',
#     oidc_client_id      => 'seamstress',
#     oidc_client_secret  => Sensitive(lookup('seamstress::oidc_client_secret')),
#     oidc_allowed_groups => ['puppet-admins'],
#   }
#
# @example Serve the site from your own web server
#   class { 'seamstress':
#     control_repo => 'https://git.example.com/puppet/control-repo.git',
#     manage_nginx => false,
#     docroot      => '/srv/www/seamstress',
#   }
class seamstress (
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
  Stdlib::Absolutepath $docroot = '/var/www/seamstress',
  Stdlib::Absolutepath $base_dir = '/var/lib/seamstress',
  Stdlib::Absolutepath $install_dir = '/opt/seamstress',
  Stdlib::Absolutepath $config_dir = '/etc/seamstress',
  String[1] $user = 'seamstress',
  String[1] $group = 'seamstress',
  Array[String[1]] $supplementary_groups = [],
  Boolean $manage_user = true,
  Stdlib::Absolutepath $usershell = '/usr/sbin/nologin',
  String[1] $poll_interval = '5min',
  String[1] $strings_version = '5.1.0',
  Boolean $manage_git = true,
  Stdlib::Absolutepath $ruby = '/opt/puppetlabs/puppet/bin/ruby',
  Stdlib::Absolutepath $puppet = '/opt/puppetlabs/bin/puppet',
  Integer[1] $keep_builds = 2,
  Integer[1] $module_timeout = 600,
  Optional[Stdlib::Absolutepath] $metrics_file = undef,
  String[1] $site_title = 'seamstress',
  Boolean $hiera = false,
  Hash[String[1], Hash[String[1], String]] $hiera_samples = {},
  Hash[String[1], Array[String]] $hiera_values = {},
  Integer[1] $hiera_values_limit = 200,
  Boolean $timer_enable = true,
  Boolean $manage_nginx = true,
  Stdlib::Port $port = 443,
  Stdlib::Host $server_name = $facts['networking']['fqdn'],
  Variant[Stdlib::Absolutepath, Pattern[/\A-----BEGIN CERTIFICATE-----/]] $tls_cert = "/etc/puppetlabs/puppet/ssl/certs/${trusted['certname']}.pem",
  Variant[Stdlib::Absolutepath, Sensitive[String[1]], Deferred] $tls_key = "/etc/puppetlabs/puppet/ssl/private_keys/${trusted['certname']}.pem",
  Enum['none', 'basic', 'oidc'] $auth = 'none',
  Hash[Pattern[/\A[^:\s]+\z/], Sensitive[Pattern[/\A(\$(6|5|y|2[aby]|apr1)\$\S+)\z/]]] $basic_auth_users = {},
  Pattern[/\A[^"\\\n]+\z/] $basic_auth_realm = $site_title,
  Optional[Stdlib::HTTPSUrl] $oidc_issuer_url = undef,
  Optional[String[1]] $oidc_client_id = undef,
  Optional[Variant[Sensitive[String[1]], Deferred]] $oidc_client_secret = undef,
  Array[String[1]] $oidc_allowed_groups = [],
  Array[String[1]] $oidc_email_domains = ['*'],
  Boolean $oidc_allow_unverified_email = false,
  String[1] $oidc_scope = 'openid email profile',
  String[1] $oidc_groups_claim = 'groups',
  Optional[Stdlib::Absolutepath] $oidc_provider_ca_file = undef,
  String[1] $oauth2_proxy_version = '7.15.6',
  Hash[Enum['amd64', 'arm64'], Pattern[/\A\h{64}\z/]] $oauth2_proxy_checksums = {
    'amd64' => '91b3e86d9c2de679a516e6696704e3fd1acf67e8b8f7be77b618f086f72fb1f0',
    'arm64' => '3593e50daa517eaa8f8d0966b95786a61a4cdf491694dc9091b8cd32daa85d56',
  },
  Stdlib::HTTPUrl $oauth2_proxy_download_base = 'https://github.com/oauth2-proxy/oauth2-proxy/releases/download',
  Stdlib::Port $oauth2_proxy_port = 4180,
) {
  if $source == 'git' and $control_repo =~ Undef {
    fail('seamstress: control_repo is required when source is git')
  }
  if $source == 'directory' and $code_dir =~ Undef and $tarballs.empty {
    fail('seamstress: source directory needs code_dir, tarballs, or both')
  }

  if $auth != 'none' and !$manage_nginx {
    fail("seamstress: auth ${auth} is enforced by nginx, so it needs manage_nginx")
  }
  if $auth == 'basic' and $basic_auth_users.empty {
    fail('seamstress: auth basic needs at least one user in basic_auth_users')
  }
  if $auth != 'basic' and !$basic_auth_users.empty {
    fail("seamstress: basic_auth_users is set but auth is ${auth}; set auth to basic to use it")
  }
  if $auth == 'oidc' {
    $missing = {
      'oidc_issuer_url'    => $oidc_issuer_url,
      'oidc_client_id'     => $oidc_client_id,
      'oidc_client_secret' => $oidc_client_secret,
    }.filter |$k, $v| { $v =~ Undef }.keys
    unless $missing.empty {
      fail("seamstress: auth oidc needs ${missing.join(', ')}")
    }
  }

  contain seamstress::install
  contain seamstress::config
  contain seamstress::service
  # Always declared: with auth other than oidc it removes what oidc left behind.
  contain seamstress::oauth2_proxy

  Class['seamstress::install']
  -> Class['seamstress::config']
  ~> Class['seamstress::service']

  if $manage_nginx {
    contain seamstress::nginx
    Class['seamstress::config'] -> Class['seamstress::nginx']
    Class['seamstress::oauth2_proxy'] -> Class['seamstress::nginx']
  }
}
