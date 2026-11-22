# @summary
#   The systemd service that runs a build and the timer that starts it.
#
# @api private
#
# @example
#   # Declared by the strings_site class; not for direct use.
#   include strings_site
class strings_site::service {
  assert_private()

  $metrics_paths = $strings_site::metrics_file ? {
    undef   => [],
    default => ["-${dirname($strings_site::metrics_file)}"],
  }

  $supplementary = $strings_site::supplementary_groups.empty ? {
    true    => {},
    default => { 'SupplementaryGroups' => $strings_site::supplementary_groups },
  }

  $exec_start = [
    $strings_site::ruby,
    "${strings_site::install_dir}/strings_site.rb",
    '--config',
    "${strings_site::config_dir}/config.json",
  ].join(' ')

  systemd::manage_unit { 'strings_site.service':
    unit_entry    => {
      'Description'   => 'Build the puppet-strings documentation site',
      'Documentation' => 'https://github.com/albatrossflavour/strings_site',
      'Wants'         => 'network-online.target',
      'After'         => 'network-online.target',
    },
    service_entry => {
      'Type'                  => 'oneshot',
      'User'                  => $strings_site::user,
      'Group'                 => $strings_site::group,
      'ExecStart'             => $exec_start,
      'WorkingDirectory'      => $strings_site::base_dir,
      'Environment'           => ["HOME=${strings_site::base_dir}", 'LANG=C.UTF-8'],
      'UMask'                 => '0022',
      'SyslogIdentifier'      => 'strings_site',
      'TimeoutStartSec'       => '2h',
      'Nice'                  => 10,
      'IOSchedulingClass'     => 'idle',
      'NoNewPrivileges'       => true,
      'PrivateTmp'            => true,
      'PrivateDevices'        => true,
      'ProtectSystem'         => 'strict',
      'ProtectHome'           => true,
      'ProtectKernelTunables' => true,
      'ProtectKernelModules'  => true,
      'ProtectControlGroups'  => true,
      'RestrictSUIDSGID'      => true,
      'LockPersonality'       => true,
      'ReadWritePaths'        => [$strings_site::docroot, $strings_site::base_dir] + $metrics_paths,
    } + $supplementary,
  }

  systemd::manage_unit { 'strings_site.timer':
    unit_entry    => {
      'Description' => 'Poll for changes to the puppet-strings documentation site',
    },
    timer_entry   => {
      'OnBootSec'       => '2min',
      'OnUnitActiveSec' => $strings_site::poll_interval,
      'Unit'            => 'strings_site.service',
    },
    install_entry => {
      'WantedBy' => 'timers.target',
    },
    enable        => $strings_site::timer_enable,
    active        => $strings_site::timer_enable,
  }
}
