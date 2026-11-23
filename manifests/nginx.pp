# @summary
#   Serves the site with nginx over HTTPS.
#
# Plain resources rather than a full nginx module: the site needs one server
# block, and this way the module adds nothing to an existing nginx setup
# beyond one file in conf.d.
#
# @api private
#
# @example
#   # Declared by the seamstress class when manage_nginx is true.
#   include seamstress
class seamstress::nginx {
  assert_private()

  $tls_dir = '/etc/nginx/seamstress'
  $worker_group = $facts['os']['family'] ? {
    'Debian' => 'www-data',
    default  => 'nginx',
  }

  package { 'nginx':
    ensure => installed,
  }

  # nginx's workers read htpasswd on each request, so their group may pass
  # through, but not list. The key stays root-only by its own mode.
  file { $tls_dir:
    ensure  => directory,
    owner   => 'root',
    group   => $worker_group,
    mode    => '0710',
    require => Package['nginx'],
  }

  # A path is copied from the node, anything else is the PEM itself.
  $cert = $seamstress::tls_cert ? {
    Stdlib::Absolutepath => { 'source' => $seamstress::tls_cert },
    default              => { 'content' => "${seamstress::tls_cert.rstrip}\n" },
  }
  $key = $seamstress::tls_key ? {
    Stdlib::Absolutepath => { 'source' => $seamstress::tls_key },
    default              => { 'content' => $seamstress::tls_key },
  }

  file { "${tls_dir}/cert.pem":
    ensure => file,
    owner  => 'root',
    group  => 'root',
    mode   => '0644',
    notify => Service['nginx'],
    *      => $cert,
  }

  file { "${tls_dir}/key.pem":
    ensure    => file,
    owner     => 'root',
    group     => 'root',
    mode      => '0600',
    show_diff => false,
    notify    => Service['nginx'],
    *         => $key,
  }

  # nginx's workers read the user file on each request, so their group needs
  # it. Each line is user:hash, and hashes only, so the file holds no password.
  $htpasswd = "${tls_dir}/htpasswd"
  $basic = $seamstress::auth == 'basic'
  if $basic {
    $lines = $seamstress::basic_auth_users.keys.sort.map |$user| {
      "${user}:${seamstress::basic_auth_users[$user].unwrap}\n"
    }
    file { $htpasswd:
      ensure    => file,
      owner     => 'root',
      group     => $worker_group,
      mode      => '0640',
      show_diff => false,
      content   => Sensitive($lines.join),
      notify    => Service['nginx'],
    }
  } else {
    file { $htpasswd:
      ensure => absent,
      notify => Service['nginx'],
    }
  }

  file { '/etc/nginx/conf.d/seamstress.conf':
    ensure  => file,
    owner   => 'root',
    group   => 'root',
    mode    => '0644',
    content => epp('seamstress/nginx.conf.epp', {
        'port'        => $seamstress::port,
        'server_name' => $seamstress::server_name,
        'docroot'     => $seamstress::docroot,
        'cert'        => "${tls_dir}/cert.pem",
        'key'         => "${tls_dir}/key.pem",
        'auth_realm'  => if $basic { $seamstress::basic_auth_realm } else { undef },
        'auth_file'   => if $basic { $htpasswd } else { undef },
        'oidc_port'   => if $seamstress::auth == 'oidc' { $seamstress::oauth2_proxy_port } else { undef },
    }),
    require => Package['nginx'],
    notify  => Service['nginx'],
  }

  service { 'nginx':
    ensure => running,
    enable => true,
  }
}
