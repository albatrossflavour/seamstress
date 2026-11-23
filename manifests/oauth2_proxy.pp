# @summary
#   Runs oauth2-proxy on 127.0.0.1 for nginx to check each request against,
#   or removes it when `auth` is not `oidc`.
#
# The release tarball is checked against its SHA-256 before it is unpacked,
# and each version unpacks into its own directory. The cookie secret is made
# on the node and never passes through the catalogue.
#
# @api private
#
# @example
#   # Declared by the strings_site class; not for direct use.
#   include strings_site
class strings_site::oauth2_proxy {
  assert_private()

  $unit = 'strings_site-oauth2-proxy.service'
  $etc = '/etc/oauth2-proxy'

  if $strings_site::auth == 'oidc' {
    $arch = $facts['os']['architecture'] ? {
      /\A(x86_64|amd64)\z/  => 'amd64',
      /\A(aarch64|arm64)\z/ => 'arm64',
      default               => $facts['os']['architecture'],
    }
    $checksum = $strings_site::oauth2_proxy_checksums[$arch]
    if $checksum =~ Undef {
      fail("strings_site: oauth2_proxy_checksums has no checksum for architecture ${arch}")
    }

    $version = $strings_site::oauth2_proxy_version
    $release = "oauth2-proxy-v${version}.linux-${arch}"
    $tarball = "/opt/oauth2-proxy/${release}.tar.gz"
    $binary = "/opt/oauth2-proxy/${release}/oauth2-proxy"
    $config = "${etc}/strings_site.cfg"
    $client_secret_file = "${etc}/client_secret"
    $cookie_secret_file = "${etc}/cookie_secret"

    group { 'oauth2-proxy':
      ensure => present,
      system => true,
    }

    user { 'oauth2-proxy':
      ensure     => present,
      system     => true,
      gid        => 'oauth2-proxy',
      managehome => false,
      shell      => '/usr/sbin/nologin',
      comment    => 'strings_site oauth2-proxy',
    }

    file { '/opt/oauth2-proxy':
      ensure => directory,
      owner  => 'root',
      group  => 'root',
      mode   => '0755',
    }

    file { $tarball:
      ensure         => file,
      owner          => 'root',
      group          => 'root',
      mode           => '0644',
      source         => "${strings_site::oauth2_proxy_download_base}/v${version}/${release}.tar.gz",
      checksum       => 'sha256',
      checksum_value => $checksum,
    }

    exec { "unpack ${release}":
      command => "tar -xzf ${tarball} --no-same-owner -C /opt/oauth2-proxy",
      path    => ['/usr/bin', '/bin'],
      creates => $binary,
      require => File[$tarball],
      notify  => Service[$unit],
    }

    file { $etc:
      ensure  => directory,
      owner   => 'root',
      group   => 'oauth2-proxy',
      mode    => '0750',
      require => Group['oauth2-proxy'],
    }

    $client_secret = $strings_site::oidc_client_secret ? {
      Sensitive => Sensitive($strings_site::oidc_client_secret.unwrap.rstrip),
      default   => $strings_site::oidc_client_secret,
    }

    # oauth2-proxy reads the whole file as the secret, so no trailing newline.
    file { $client_secret_file:
      ensure    => file,
      owner     => 'root',
      group     => 'oauth2-proxy',
      mode      => '0640',
      show_diff => false,
      content   => $client_secret,
      notify    => Service[$unit],
    }

    # 32 raw bytes, made once on the node. oauth2-proxy takes the file as it is.
    exec { 'oauth2-proxy cookie secret':
      command  => "head -c 32 /dev/urandom > ${cookie_secret_file}",
      provider => 'shell',
      path     => ['/usr/bin', '/bin'],
      umask    => '027',
      creates  => $cookie_secret_file,
      require  => File[$etc],
      notify   => Service[$unit],
    }

    file { $cookie_secret_file:
      ensure  => file,
      owner   => 'root',
      group   => 'oauth2-proxy',
      mode    => '0640',
      require => Exec['oauth2-proxy cookie secret'],
    }

    $port_suffix = $strings_site::port ? {
      443     => '',
      default => ":${strings_site::port}",
    }

    $settings = {
      'provider'              => 'oidc',
      'oidc_issuer_url'       => $strings_site::oidc_issuer_url,
      'client_id'             => $strings_site::oidc_client_id,
      'client_secret_file'    => $client_secret_file,
      'cookie_secret_file'    => $cookie_secret_file,
      'redirect_url'          => "https://${strings_site::server_name}${port_suffix}/oauth2/callback",
      'http_address'          => "127.0.0.1:${strings_site::oauth2_proxy_port}",
      'reverse_proxy'         => true,
      'trusted_proxy_ips'     => ['127.0.0.1/32'],
      'upstreams'             => ['static://202'],
      'email_domains'         => $strings_site::oidc_email_domains,
      'allowed_groups'        => $strings_site::oidc_allowed_groups.empty ? {
        true    => undef,
        default => $strings_site::oidc_allowed_groups,
      },
      'oidc_groups_claim'     => $strings_site::oidc_groups_claim,
      'scope'                 => $strings_site::oidc_scope,
      'cookie_secure'         => true,
      # __Host- makes the browser refuse the cookie unless it is Secure, on
      # path / and has no Domain, which is how oauth2-proxy sets it here.
      'cookie_name'           => '__Host-strings_site',
      'skip_provider_button'  => true,
      'code_challenge_method' => 'S256',
      'set_xauthrequest'      => true,
      'provider_ca_files'     => $strings_site::oidc_provider_ca_file ? {
        undef   => undef,
        default => [$strings_site::oidc_provider_ca_file],
      },
    }.filter |$k, $v| { $v =~ NotUndef }

    # A JSON string, array, or boolean is also a valid TOML value, escaping
    # included.
    $toml = $settings.map |$k, $v| { "${k} = ${stdlib::to_json($v)}\n" }.join

    file { $config:
      ensure  => file,
      owner   => 'root',
      group   => 'oauth2-proxy',
      mode    => '0640',
      content => "# Managed by Puppet (strings_site). Local changes will be overwritten.\n${toml}",
      notify  => Service[$unit],
    }

    systemd::manage_unit { $unit:
      unit_entry    => {
        'Description'   => 'oauth2-proxy for the puppet-strings documentation site',
        'Documentation' => 'https://github.com/albatrossflavour/strings_site',
        'Wants'         => 'network-online.target',
        'After'         => 'network-online.target',
      },
      service_entry => {
        'User'                    => 'oauth2-proxy',
        'Group'                   => 'oauth2-proxy',
        'ExecStart'               => "${binary} --config=${config}",
        'Restart'                 => 'on-failure',
        'SyslogIdentifier'        => 'strings_site-oauth2-proxy',
        'NoNewPrivileges'         => true,
        'ProtectSystem'           => 'strict',
        'ProtectHome'             => true,
        'PrivateTmp'              => true,
        'PrivateDevices'          => true,
        'ProtectKernelTunables'   => true,
        'ProtectKernelModules'    => true,
        'ProtectControlGroups'    => true,
        'RestrictAddressFamilies' => ['AF_INET', 'AF_INET6', 'AF_UNIX'],
        'CapabilityBoundingSet'   => '',
        'LockPersonality'         => true,
        'MemoryDenyWriteExecute'  => true,
      },
      install_entry => {
        'WantedBy' => 'multi-user.target',
      },
      enable        => true,
      active        => true,
      require       => [User['oauth2-proxy'], Exec['oauth2-proxy cookie secret'], File[$cookie_secret_file]],
    }
  } else {
    systemd::manage_unit { $unit:
      ensure => absent,
      enable => false,
      active => false,
    }

    # Takes the client and cookie secrets with it. /opt/oauth2-proxy is left.
    file { $etc:
      ensure  => absent,
      recurse => true,
      force   => true,
      require => Systemd::Manage_unit[$unit],
    }
  }
}
