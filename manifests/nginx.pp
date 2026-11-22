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

  package { 'nginx':
    ensure => installed,
  }

  file { $tls_dir:
    ensure  => directory,
    owner   => 'root',
    group   => 'root',
    mode    => '0700',
    require => Package['nginx'],
  }

  file { "${tls_dir}/cert.pem":
    ensure => file,
    owner  => 'root',
    group  => 'root',
    mode   => '0644',
    source => $strings_site::tls_cert,
    notify => Service['nginx'],
  }

  file { "${tls_dir}/key.pem":
    ensure    => file,
    owner     => 'root',
    group     => 'root',
    mode      => '0600',
    show_diff => false,
    source    => $strings_site::tls_key,
    notify    => Service['nginx'],
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
    }),
    require => Package['nginx'],
    notify  => Service['nginx'],
  }

  service { 'nginx':
    ensure => running,
    enable => true,
  }
}
