# @summary
#   Writes the build configuration, the git credentials, and the directories
#   the build writes to.
#
# @api private
#
# @example
#   # Declared by the seamstress class; not for direct use.
#   include seamstress
class seamstress::config {
  assert_private()

  $user = $seamstress::user
  $group = $seamstress::group
  $ssh_dir = "${seamstress::base_dir}/.ssh"

  file { [$seamstress::base_dir, "${seamstress::base_dir}/cache"]:
    ensure => directory,
    owner  => $user,
    group  => $group,
    mode   => '0750',
  }

  file { $ssh_dir:
    ensure  => directory,
    owner   => $user,
    group   => $group,
    mode    => '0700',
    recurse => true,
    purge   => true,
    force   => true,
  }

  # One file per pattern, named by a hash of the pattern so the name is
  # stable and says nothing about the repository.
  $key_files = $seamstress::deploy_keys.reduce({}) |$memo, $pair| {
    $memo + { $pair[0] => "${ssh_dir}/deploy_${sha256($pair[0])[0, 16]}" }
  }

  $seamstress::deploy_keys.each |$pattern, $key| {
    file { $key_files[$pattern]:
      ensure    => file,
      owner     => $user,
      group     => $group,
      mode      => '0600',
      show_diff => false,
      content   => Sensitive("${strip($key.unwrap)}\n"),
    }
  }

  # With no hosts given, accept-new writes here; replace => false keeps what
  # it learnt across Puppet runs.
  $known_hosts = "${ssh_dir}/known_hosts"
  file { $known_hosts:
    ensure  => file,
    owner   => $user,
    group   => $group,
    mode    => '0600',
    replace => !$seamstress::ssh_known_hosts.empty,
    content => $seamstress::ssh_known_hosts.empty ? {
      true    => '',
      default => "${seamstress::ssh_known_hosts.join("\n")}\n",
    },
  }

  if $seamstress::forge_token =~ NotUndef {
    $forge_token_file = "${seamstress::base_dir}/.forge_token"
    file { $forge_token_file:
      ensure    => file,
      owner     => $user,
      group     => $group,
      mode      => '0600',
      show_diff => false,
      content   => Sensitive("${seamstress::forge_token.unwrap}\n"),
    }
  } else {
    $forge_token_file = undef
    file { "${seamstress::base_dir}/.forge_token":
      ensure => absent,
    }
  }

  $docroot_parent = dirname($seamstress::docroot)
  if $docroot_parent != '/' {
    ensure_resource('file', $docroot_parent, { 'ensure' => 'directory' })
  }

  file { $seamstress::docroot:
    ensure => directory,
    owner  => $user,
    group  => $group,
    mode   => '0755',
  }

  file { $seamstress::config_dir:
    ensure => directory,
    owner  => 'root',
    group  => $group,
    mode   => '0750',
  }

  $config = {
    'source'                   => $seamstress::source,
    'control_repo'             => $seamstress::control_repo,
    'code_dir'                 => $seamstress::code_dir,
    'tarballs'                 => $seamstress::tarballs,
    'environments'             => $seamstress::environments,
    'exclude_environments'     => $seamstress::exclude_environments,
    'local_module_dirs'        => $seamstress::local_module_dirs,
    'docroot'                  => $seamstress::docroot,
    'cache_dir'                => "${seamstress::base_dir}/cache",
    'state_file'               => "${seamstress::base_dir}/state.json",
    'puppet'                   => $seamstress::puppet,
    'deploy_keys'              => $key_files,
    'known_hosts_file'         => $known_hosts,
    'strict_host_key_checking' => $seamstress::strict_host_key_checking,
    'forge_url'                => $seamstress::forge_url,
    'forge_token_file'         => $forge_token_file,
    'keep_builds'              => $seamstress::keep_builds,
    'module_timeout'           => $seamstress::module_timeout,
    'metrics_file'             => $seamstress::metrics_file,
    'site_title'               => $seamstress::site_title,
    'hiera'                    => $seamstress::hiera,
    'hiera_samples'            => $seamstress::hiera_samples,
    'hiera_values'             => $seamstress::hiera_values,
  }

  file { "${seamstress::config_dir}/config.json":
    ensure  => file,
    owner   => 'root',
    group   => $group,
    mode    => '0640',
    content => "${stdlib::to_json_pretty($config.filter |$k, $v| { $v =~ NotUndef })}\n",
  }
}
