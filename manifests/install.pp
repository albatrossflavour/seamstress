# @summary
#   Installs puppet-strings, git, the service user, and the build script.
#
# @api private
#
# @example
#   # Declared by the strings_site class; not for direct use.
#   include strings_site
class strings_site::install {
  assert_private()

  package { 'puppet-strings':
    ensure   => $strings_site::strings_version,
    provider => 'puppet_gem',
  }

  if $strings_site::manage_git {
    stdlib::ensure_packages(['git'])
  }

  if $strings_site::manage_user {
    group { $strings_site::group:
      ensure => present,
      system => true,
    }

    user { $strings_site::user:
      ensure     => present,
      system     => true,
      gid        => $strings_site::group,
      groups     => $strings_site::supplementary_groups,
      home       => $strings_site::base_dir,
      managehome => false,
      shell      => '/usr/sbin/nologin',
      comment    => 'strings_site documentation builder',
    }
  }

  file { $strings_site::install_dir:
    ensure  => directory,
    owner   => 'root',
    group   => 'root',
    mode    => '0644',
    recurse => true,
    purge   => true,
    force   => true,
    source  => 'puppet:///modules/strings_site/app',
  }
}
