# @summary
#   Installs puppet-strings, git, the service user, and the build script.
#
# @api private
#
# @example
#   # Declared by the seamstress class; not for direct use.
#   include seamstress
class seamstress::install {
  assert_private()

  package { 'puppet-strings':
    ensure   => $seamstress::strings_version,
    provider => 'puppet_gem',
  }

  if $seamstress::manage_git {
    stdlib::ensure_packages(['git'])
  }

  if $seamstress::manage_user {
    group { $seamstress::group:
      ensure => present,
      system => true,
    }

    user { $seamstress::user:
      ensure     => present,
      system     => true,
      gid        => $seamstress::group,
      groups     => $seamstress::supplementary_groups,
      home       => $seamstress::base_dir,
      managehome => false,
      shell      => $seamstress::usershell,
      comment    => 'seamstress documentation builder',
    }
  }

  file { $seamstress::install_dir:
    ensure  => directory,
    owner   => 'root',
    group   => 'root',
    mode    => '0644',
    recurse => true,
    purge   => true,
    force   => true,
    source  => 'puppet:///modules/seamstress/app',
  }
}
