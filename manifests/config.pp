# @summary
#   Writes the build configuration, the git credentials, and the directories
#   the build writes to.
#
# @api private
#
# @example
#   # Declared by the strings_site class; not for direct use.
#   include strings_site
class strings_site::config {
  assert_private()

  $user = $strings_site::user
  $group = $strings_site::group
  $ssh_dir = "${strings_site::base_dir}/.ssh"

  file { [$strings_site::base_dir, "${strings_site::base_dir}/cache"]:
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
  $key_files = $strings_site::deploy_keys.reduce({}) |$memo, $pair| {
    $memo + { $pair[0] => "${ssh_dir}/deploy_${sha256($pair[0])[0, 16]}" }
  }

  $strings_site::deploy_keys.each |$pattern, $key| {
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
    replace => !$strings_site::ssh_known_hosts.empty,
    content => $strings_site::ssh_known_hosts.empty ? {
      true    => '',
      default => "${strings_site::ssh_known_hosts.join("\n")}\n",
    },
  }

  if $strings_site::forge_token =~ NotUndef {
    $forge_token_file = "${strings_site::base_dir}/.forge_token"
    file { $forge_token_file:
      ensure    => file,
      owner     => $user,
      group     => $group,
      mode      => '0600',
      show_diff => false,
      content   => Sensitive("${strings_site::forge_token.unwrap}\n"),
    }
  } else {
    $forge_token_file = undef
    file { "${strings_site::base_dir}/.forge_token":
      ensure => absent,
    }
  }

  $docroot_parent = dirname($strings_site::docroot)
  if $docroot_parent != '/' {
    ensure_resource('file', $docroot_parent, { 'ensure' => 'directory' })
  }

  file { $strings_site::docroot:
    ensure => directory,
    owner  => $user,
    group  => $group,
    mode   => '0755',
  }

  file { $strings_site::config_dir:
    ensure => directory,
    owner  => 'root',
    group  => $group,
    mode   => '0750',
  }

  $config = {
    'source'                   => $strings_site::source,
    'control_repo'             => $strings_site::control_repo,
    'code_dir'                 => $strings_site::code_dir,
    'tarballs'                 => $strings_site::tarballs,
    'environments'             => $strings_site::environments,
    'exclude_environments'     => $strings_site::exclude_environments,
    'local_module_dirs'        => $strings_site::local_module_dirs,
    'docroot'                  => $strings_site::docroot,
    'cache_dir'                => "${strings_site::base_dir}/cache",
    'state_file'               => "${strings_site::base_dir}/state.json",
    'puppet'                   => $strings_site::puppet,
    'deploy_keys'              => $key_files,
    'known_hosts_file'         => $known_hosts,
    'strict_host_key_checking' => $strings_site::strict_host_key_checking,
    'forge_url'                => $strings_site::forge_url,
    'forge_token_file'         => $forge_token_file,
    'keep_builds'              => $strings_site::keep_builds,
    'module_timeout'           => $strings_site::module_timeout,
    'metrics_file'             => $strings_site::metrics_file,
    'site_title'               => $strings_site::site_title,
  }

  file { "${strings_site::config_dir}/config.json":
    ensure  => file,
    owner   => 'root',
    group   => $group,
    mode    => '0640',
    content => "${stdlib::to_json_pretty($config.filter |$k, $v| { $v =~ NotUndef })}\n",
  }
}
