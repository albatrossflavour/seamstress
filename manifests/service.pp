# @summary
#   The systemd service that runs a build and the timer that starts it.
#
# @api private
#
# @example
#   # Declared by the seamstress class; not for direct use.
#   include seamstress
class seamstress::service {
  assert_private()

  $metrics_paths = $seamstress::metrics_file ? {
    undef   => [],
    default => ["-${dirname($seamstress::metrics_file)}"],
  }

  $supplementary = $seamstress::supplementary_groups.empty ? {
    true    => {},
    default => { 'SupplementaryGroups' => $seamstress::supplementary_groups },
  }

  $exec_start = [
    $seamstress::ruby,
    "${seamstress::install_dir}/seamstress.rb",
    '--config',
    "${seamstress::config_dir}/config.json",
  ].join(' ')

  systemd::manage_unit { 'seamstress.service':
    unit_entry    => {
      'Description'   => 'Build the puppet-strings documentation site',
      'Documentation' => 'https://github.com/albatrossflavour/seamstress',
      'Wants'         => 'network-online.target',
      'After'         => 'network-online.target',
    },
    service_entry => {
      'Type'                  => 'oneshot',
      'User'                  => $seamstress::user,
      'Group'                 => $seamstress::group,
      'ExecStart'             => $exec_start,
      'WorkingDirectory'      => $seamstress::base_dir,
      'Environment'           => ["HOME=${seamstress::base_dir}", 'LANG=C.UTF-8'],
      'UMask'                 => '0022',
      'SyslogIdentifier'      => 'seamstress',
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
      'ReadWritePaths'        => [$seamstress::docroot, $seamstress::base_dir] + $metrics_paths,
    } + $supplementary,
  }

  systemd::manage_unit { 'seamstress.timer':
    unit_entry    => {
      'Description' => 'Poll for changes to the puppet-strings documentation site',
    },
    timer_entry   => {
      'OnBootSec'       => '2min',
      'OnUnitActiveSec' => $seamstress::poll_interval,
      'Unit'            => 'seamstress.service',
    },
    install_entry => {
      'WantedBy' => 'timers.target',
    },
    enable        => $seamstress::timer_enable,
    active        => $seamstress::timer_enable,
  }
}
