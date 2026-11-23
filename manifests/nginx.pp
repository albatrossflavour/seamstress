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
#   # Declared by the strings_site class when manage_nginx is true.
#   include strings_site
class strings_site::nginx {
  assert_private()

  $tls_dir = '/etc/nginx/strings_site'
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
  $cert = $strings_site::tls_cert ? {
    Stdlib::Absolutepath => { 'source' => $strings_site::tls_cert },
    default              => { 'content' => "${strings_site::tls_cert.rstrip}\n" },
  }
  $key = $strings_site::tls_key ? {
    Stdlib::Absolutepath => { 'source' => $strings_site::tls_key },
    default              => { 'content' => $strings_site::tls_key },
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
  $basic = $strings_site::auth == 'basic'
  if $basic {
    $lines = $strings_site::basic_auth_users.keys.sort.map |$user| {
      "${user}:${strings_site::basic_auth_users[$user].unwrap}\n"
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

  file { '/etc/nginx/conf.d/strings_site.conf':
    ensure  => file,
    owner   => 'root',
    group   => 'root',
    mode    => '0644',
    content => epp('strings_site/nginx.conf.epp', {
        'port'        => $strings_site::port,
        'server_name' => $strings_site::server_name,
        'docroot'     => $strings_site::docroot,
        'cert'        => "${tls_dir}/cert.pem",
        'key'         => "${tls_dir}/key.pem",
        'auth_realm'  => if $basic { $strings_site::basic_auth_realm } else { undef },
        'auth_file'   => if $basic { $htpasswd } else { undef },
        'oidc_port'   => if $strings_site::auth == 'oidc' { $strings_site::oauth2_proxy_port } else { undef },
    }),
    require => Package['nginx'],
    notify  => Service['nginx'],
  }

  service { 'nginx':
    ensure => running,
    enable => true,
  }
}
