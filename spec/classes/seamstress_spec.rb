# frozen_string_literal: true

require 'spec_helper'

describe 'seamstress' do
  let(:node) { 'docs.example.com' }
  let(:git_params) { { control_repo: 'git@git.example.com:puppet/control-repo.git' } }
  let(:build_config) { JSON.parse(catalogue.resource('File', '/etc/seamstress/config.json')[:content]) }
  let(:service_entry) { catalogue.resource('Systemd::Manage_unit', 'seamstress.service')[:service_entry] }

  on_supported_os.each do |os, os_facts|
    context "when on #{os}" do
      let(:facts) { os_facts }

      context 'with no source settings' do
        it { is_expected.to compile.and_raise_error(/control_repo is required/) }
      end

      context 'when directory mode has nothing to read' do
        let(:params) { { source: 'directory' } }

        it { is_expected.to compile.and_raise_error(/needs code_dir, tarballs, or both/) }
      end

      context 'when usershell is set' do
        let(:params) { git_params.merge(usershell: '/sbin/nologin') }

        it { is_expected.to contain_user('seamstress').with_shell('/sbin/nologin') }
      end

      context 'when in git mode with defaults' do
        let(:params) { git_params }

        it { is_expected.to compile.with_all_deps }

        it { is_expected.to contain_package('puppet-strings').with(ensure: '5.1.0', provider: 'puppet_gem') }
        it { is_expected.to contain_package('git') }
        it { is_expected.to contain_group('seamstress').with(system: true) }

        it {
          is_expected.to contain_user('seamstress').with(
            system: true, home: '/var/lib/seamstress', shell: '/usr/sbin/nologin', managehome: false
          )
        }

        it {
          is_expected.to contain_file('/opt/seamstress')
            .with(source: 'puppet:///modules/seamstress/app', recurse: true, purge: true)
        }

        it { is_expected.to contain_file('/var/lib/seamstress').with(owner: 'seamstress', mode: '0750') }
        it { is_expected.to contain_file('/var/lib/seamstress/.ssh').with(owner: 'seamstress', mode: '0700', purge: true) }
        it { is_expected.to contain_file('/var/www/seamstress').with(owner: 'seamstress', mode: '0755') }
        it { is_expected.to contain_file('/var/www').with_ensure('directory') }
        it { is_expected.to contain_file('/var/lib/seamstress/.forge_token').with_ensure('absent') }
        it { is_expected.to contain_file('/var/lib/seamstress/.ssh/known_hosts').with(replace: false, mode: '0600') }
        it { is_expected.to contain_file('/etc/seamstress/config.json').with(owner: 'root', group: 'seamstress', mode: '0640') }

        it 'writes the build configuration' do
          expect(build_config).to include(
            'source' => 'git',
            'control_repo' => 'git@git.example.com:puppet/control-repo.git',
            'environments' => [],
            'exclude_environments' => [],
            'docroot' => '/var/www/seamstress',
            'cache_dir' => '/var/lib/seamstress/cache',
            'deploy_keys' => {},
            'strict_host_key_checking' => 'accept-new',
            'keep_builds' => 2,
            'hiera' => false,
            'hiera_samples' => {},
            'hiera_values' => {},
            'hiera_values_limit' => 200,
            'site_title' => 'seamstress'
          )
          expect(build_config).not_to have_key('metrics_file')
          expect(build_config).not_to have_key('code_dir')
        end

        it 'hardens the service' do
          expect(service_entry).to include(
            'Type' => 'oneshot', 'User' => 'seamstress', 'Group' => 'seamstress',
            'NoNewPrivileges' => true, 'PrivateTmp' => true, 'ProtectSystem' => 'strict',
            'ReadWritePaths' => ['/var/www/seamstress', '/var/lib/seamstress'],
            'ExecStart' => '/opt/puppetlabs/puppet/bin/ruby /opt/seamstress/seamstress.rb --config /etc/seamstress/config.json'
          )
          expect(service_entry).not_to have_key('SupplementaryGroups')
        end

        it {
          is_expected.to contain_systemd__manage_unit('seamstress.timer').with(
            enable: true, active: true,
            timer_entry: { 'OnBootSec' => '2min', 'OnUnitActiveSec' => '5min', 'Unit' => 'seamstress.service' }
          )
        }

        it { is_expected.to contain_package('nginx') }
        it { is_expected.to contain_service('nginx').with(ensure: 'running', enable: true) }

        it {
          is_expected.to contain_file('/etc/nginx/seamstress/cert.pem')
            .with_source('/etc/puppetlabs/puppet/ssl/certs/docs.example.com.pem')
        }

        it {
          is_expected.to contain_file('/etc/nginx/seamstress/key.pem').with(
            source: '/etc/puppetlabs/puppet/ssl/private_keys/docs.example.com.pem', mode: '0600', show_diff: false
          )
        }

        it {
          is_expected.to contain_file('/etc/nginx/conf.d/seamstress.conf')
            .with_content(/listen 443 ssl;/)
            .with_content(/server_name docs\.example\.com;/)
            .with_content(%r{root  /var/www/seamstress;})
            .that_notifies('Service[nginx]')
        }

        it 'allows no inline script, since module docs are untrusted' do
          csp = catalogue.resource('File',
                                   '/etc/nginx/conf.d/seamstress.conf')[:content].scan(/Content-Security-Policy "([^"]+)"/).flatten
          expect(csp.size).to eq(2)
          expect(csp).to all(include("script-src 'self';").and(include("default-src 'self'")))
        end
      end

      context 'with deploy keys, known hosts, and a Forge token' do
        let(:params) do
          git_params.merge(
            deploy_keys: {
              'git@git.example.com:puppet/*' => sensitive("-----BEGIN OPENSSH PRIVATE KEY-----\nAAAA\n-----END OPENSSH PRIVATE KEY-----"),
              'git@git.example.com:puppet/secret.git' => sensitive('second key')
            },
            ssh_known_hosts: ['git.example.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExample'],
            strict_host_key_checking: 'yes',
            forge_token: sensitive('forge-token')
          )
        end

        it { is_expected.to compile.with_all_deps }

        it 'writes each key to its own 0600 file and maps the pattern to it' do
          keys = build_config['deploy_keys']
          expect(keys.keys).to contain_exactly('git@git.example.com:puppet/*', 'git@git.example.com:puppet/secret.git')
          keys.each_value do |path|
            expect(path).to match(%r{\A/var/lib/seamstress/\.ssh/deploy_\h{16}\z})
            expect(catalogue).to contain_file(path).with(owner: 'seamstress', mode: '0600', show_diff: false)
          end
          expect(keys.values.uniq.size).to eq(2)
        end

        it 'keeps the key out of the configuration file' do
          expect(catalogue.resource('File', '/etc/seamstress/config.json')[:content]).not_to include('PRIVATE KEY')
        end

        it {
          is_expected.to contain_file('/var/lib/seamstress/.ssh/known_hosts')
            .with(replace: true, content: "git.example.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExample\n")
        }

        it { is_expected.to contain_file('/var/lib/seamstress/.forge_token').with(mode: '0600', show_diff: false) }

        it {
          expect(build_config).to include('strict_host_key_checking' => 'yes', 'forge_token_file' => '/var/lib/seamstress/.forge_token')
        }
      end

      context 'when in directory mode with a tarball' do
        let(:params) do
          {
            source: 'directory',
            code_dir: '/srv/puppet/environments',
            tarballs: { 'staging' => '/srv/drop/staging.tar.gz' },
            environments: %w[production staging],
            exclude_environments: ['^feature_'],
            supplementary_groups: ['puppetcode'],
            metrics_file: '/var/lib/node_exporter/textfile/seamstress.prom',
            hiera: true,
            hiera_samples: { 'A web server' => { 'trusted.extensions.pp_role' => 'role::web' } },
            hiera_values: { 'trusted.certname' => ['web1.example.com'] }
          }
        end

        it { is_expected.to compile.with_all_deps }
        it { is_expected.to contain_user('seamstress').with_groups(['puppetcode']) }

        it 'writes the directory settings' do
          expect(build_config).to include(
            'source' => 'directory',
            'code_dir' => '/srv/puppet/environments',
            'tarballs' => { 'staging' => '/srv/drop/staging.tar.gz' },
            'environments' => %w[production staging],
            'exclude_environments' => ['^feature_'],
            'metrics_file' => '/var/lib/node_exporter/textfile/seamstress.prom',
            'hiera' => true,
            'hiera_samples' => { 'A web server' => { 'trusted.extensions.pp_role' => 'role::web' } },
            'hiera_values' => { 'trusted.certname' => ['web1.example.com'] }
          )
          expect(build_config).not_to have_key('control_repo')
        end

        it 'lets the service write the metrics directory and read the code' do
          expect(service_entry).to include(
            'ReadWritePaths' => ['/var/www/seamstress', '/var/lib/seamstress', '-/var/lib/node_exporter/textfile'],
            'SupplementaryGroups' => ['puppetcode']
          )
        end
      end

      context 'with nginx, git, and the user left to someone else' do
        let(:params) do
          git_params.merge(
            manage_nginx: false, manage_git: false, manage_user: false, timer_enable: false,
            docroot: '/srv/strings', poll_interval: '15min', strings_version: '4.1.3', user: 'docs', group: 'docs'
          )
        end

        it { is_expected.to compile.with_all_deps }
        it { is_expected.not_to contain_package('nginx') }
        it { is_expected.not_to contain_class('seamstress::nginx') }
        it { is_expected.not_to contain_package('git') }
        it { is_expected.not_to contain_user('docs') }
        it { is_expected.to contain_package('puppet-strings').with_ensure('4.1.3') }
        it { is_expected.to contain_file('/srv/strings').with_owner('docs') }
        it { is_expected.to contain_file('/srv').with_ensure('directory') }
        it { is_expected.to contain_systemd__manage_unit('seamstress.timer').with(enable: false, active: false) }

        it 'polls at the configured interval' do
          entry = catalogue.resource('Systemd::Manage_unit', 'seamstress.timer')[:timer_entry]
          expect(entry['OnUnitActiveSec']).to eq('15min')
        end
      end

      context 'with a custom port, name, and certificate' do
        let(:params) do
          git_params.merge(
            port: 8443, server_name: 'strings.example.com',
            tls_cert: '/etc/pki/tls/certs/strings.pem', tls_key: '/etc/pki/tls/private/strings.key'
          )
        end

        it {
          is_expected.to contain_file('/etc/nginx/conf.d/seamstress.conf')
            .with_content(/listen 8443 ssl;/)
            .with_content(/server_name strings\.example\.com;/)
        }

        it { is_expected.to contain_file('/etc/nginx/seamstress/cert.pem').with_source('/etc/pki/tls/certs/strings.pem') }
        it { is_expected.to contain_file('/etc/nginx/seamstress/key.pem').with_source('/etc/pki/tls/private/strings.key') }
      end
    end
  end
end
