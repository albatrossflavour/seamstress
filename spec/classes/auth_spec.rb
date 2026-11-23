# frozen_string_literal: true

require 'spec_helper'

describe 'seamstress' do
  let(:node) { 'docs.example.com' }
  let(:git_params) { { control_repo: 'git@git.example.com:puppet/control-repo.git' } }
  let(:nginx_conf) { catalogue.resource('File', '/etc/nginx/conf.d/seamstress.conf')[:content] }
  let(:pw_hash) { '$6$saltsalt$Mj1qkqFfyfNTzVnqzG2Zp5r5d.P2Q2GhQUmZ8sQ7sFfr6S1Wq8JQZmGr2v0vGpZKH8n6aQ0Xb0e4y6yQ2nYb0/' }
  let(:oidc_params) do
    git_params.merge(
      auth: 'oidc',
      oidc_issuer_url: 'https://login.example.com/realms/staff',
      oidc_client_id: 'seamstress',
      oidc_client_secret: sensitive("s3cret\n")
    )
  end
  let(:proxy_config) { catalogue.resource('File', '/etc/oauth2-proxy/seamstress.cfg')[:content] }
  let(:proxy_unit) { catalogue.resource('Systemd::Manage_unit', 'seamstress-oauth2-proxy.service') }

  # rspec-puppet-facts gives symbol keys at the top and string keys below.
  def with_arch(facts, arch)
    facts.merge(os: facts[:os].merge('architecture' => arch))
  end

  def deferred(call)
    RSpec::Puppet::RawString.new(call)
  end

  on_supported_os.each do |os, os_facts|
    context "when on #{os}" do
      let(:facts) { os_facts }
      let(:debian) { os_facts[:os]['family'] == 'Debian' }

      context 'when auth is set but nginx is not managed' do
        let(:params) { oidc_params.merge(manage_nginx: false) }

        it { is_expected.to compile.and_raise_error(/auth oidc is enforced by nginx, so it needs manage_nginx/) }
      end

      context 'when auth is basic with no users' do
        let(:params) { git_params.merge(auth: 'basic') }

        it { is_expected.to compile.and_raise_error(/auth basic needs at least one user/) }
      end

      context 'when users are given but auth is not basic' do
        let(:params) { git_params.merge(basic_auth_users: { 'alice' => sensitive(pw_hash) }) }

        it { is_expected.to compile.and_raise_error(/basic_auth_users is set but auth is none/) }
      end

      context 'when auth is oidc with nothing else' do
        let(:params) { git_params.merge(auth: 'oidc') }

        it { is_expected.to compile.and_raise_error(/auth oidc needs oidc_issuer_url, oidc_client_id, oidc_client_secret/) }
      end

      context 'when auth is oidc without a secret' do
        let(:params) { oidc_params.merge(oidc_client_secret: :undef) }

        it { is_expected.to compile.and_raise_error(/auth oidc needs oidc_client_secret \(/) }
      end

      context 'when auth is none' do
        let(:params) { git_params }

        it { is_expected.to compile.with_all_deps }

        it 'renders no auth' do
          expect(nginx_conf).not_to match(/auth_basic|auth_request|oauth2/)
        end

        it { is_expected.to contain_file('/etc/nginx/seamstress/htpasswd').with_ensure('absent') }

        it {
          is_expected.to contain_systemd__manage_unit('seamstress-oauth2-proxy.service')
            .with(ensure: 'absent', enable: false, active: false)
        }

        it { is_expected.to contain_file('/etc/oauth2-proxy').with(ensure: 'absent', recurse: true, force: true) }
        it { is_expected.not_to contain_file('/opt/oauth2-proxy') }
        it { is_expected.not_to contain_user('oauth2-proxy') }
      end

      context 'when auth is basic' do
        let(:params) do
          git_params.merge(
            auth: 'basic',
            basic_auth_users: { 'zoe' => sensitive('$apr1$abcdefgh$0123456789abcdefghijk/'), 'alice' => sensitive(pw_hash) },
            basic_auth_realm: 'Docs'
          )
        end

        it { is_expected.to compile.with_all_deps }

        it 'writes the users sorted, readable by the nginx workers only' do
          file = catalogue.resource('File', '/etc/nginx/seamstress/htpasswd')
          expect(file[:content]).to eq("alice:#{pw_hash}\nzoe:$apr1$abcdefgh$0123456789abcdefghijk/\n")
          expect(file[:owner]).to eq('root')
          expect(file[:group]).to eq(debian ? 'www-data' : 'nginx')
          expect(file[:mode]).to eq('0640')
          expect(file[:show_diff]).to be(false)
        end

        it 'lets the nginx workers through the directory to it' do
          expect(catalogue).to contain_file('/etc/nginx/seamstress')
            .with(owner: 'root', group: debian ? 'www-data' : 'nginx', mode: '0710')
        end

        it 'asks for credentials on every location' do
          expect(nginx_conf).to include(%(auth_basic           "Docs";))
            .and include('auth_basic_user_file /etc/nginx/seamstress/htpasswd;')
          expect(nginx_conf).not_to include('auth_request')
        end

        it { is_expected.to contain_systemd__manage_unit('seamstress-oauth2-proxy.service').with_ensure('absent') }
      end

      context 'when a basic auth password is not hashed' do
        let(:params) { git_params.merge(auth: 'basic', basic_auth_users: { 'alice' => sensitive('hunter2') }) }

        it { is_expected.to compile.and_raise_error(/basic_auth_users/) }
      end

      context 'when auth is oidc' do
        let(:params) { oidc_params }
        let(:arch) { os_facts[:os]['architecture'] }
        let(:release) { 'oauth2-proxy-v7.15.6.linux-amd64' }

        it { is_expected.to compile.with_all_deps }
        it { is_expected.to contain_group('oauth2-proxy').with(system: true) }

        it {
          is_expected.to contain_user('oauth2-proxy')
            .with(system: true, gid: 'oauth2-proxy', shell: '/usr/sbin/nologin', managehome: false, home: nil)
        }

        it 'downloads the amd64 release and checks it before unpacking' do
          expect(arch).to match(/\A(x86_64|amd64)\z/)
          expect(catalogue).to contain_file("/opt/oauth2-proxy/#{release}.tar.gz").with(
            source: "https://github.com/oauth2-proxy/oauth2-proxy/releases/download/v7.15.6/#{release}.tar.gz",
            checksum: 'sha256',
            checksum_value: '91b3e86d9c2de679a516e6696704e3fd1acf67e8b8f7be77b618f086f72fb1f0'
          )
          expect(catalogue).to contain_exec("unpack #{release}").with(
            command: "tar -xzf /opt/oauth2-proxy/#{release}.tar.gz --no-same-owner -C /opt/oauth2-proxy",
            creates: "/opt/oauth2-proxy/#{release}/oauth2-proxy"
          ).that_requires("File[/opt/oauth2-proxy/#{release}.tar.gz]")
                                                                .that_notifies('Service[seamstress-oauth2-proxy.service]')
        end

        it {
          is_expected.to contain_file('/etc/oauth2-proxy').with(ensure: 'directory', owner: 'root', group: 'oauth2-proxy', mode: '0750')
        }

        it 'writes the configuration' do
          expect(proxy_config).to include(
            'provider = "oidc"',
            'oidc_issuer_url = "https://login.example.com/realms/staff"',
            'client_id = "seamstress"',
            'client_secret_file = "/etc/oauth2-proxy/client_secret"',
            'cookie_secret_file = "/etc/oauth2-proxy/cookie_secret"',
            'redirect_url = "https://docs.example.com/oauth2/callback"',
            'http_address = "127.0.0.1:4180"',
            'reverse_proxy = true',
            'trusted_proxy_ips = ["127.0.0.1/32"]',
            'upstreams = ["static://202"]',
            'email_domains = ["*"]',
            'oidc_groups_claim = "groups"',
            'scope = "openid email profile"',
            'cookie_secure = true',
            'cookie_name = "__Host-seamstress"',
            'skip_provider_button = true',
            'code_challenge_method = "S256"',
            'set_xauthrequest = true'
          )
          expect(proxy_config).not_to match(/allowed_groups|provider_ca_files|cookie_secret =|client_secret =/)
          expect(catalogue).to contain_file('/etc/oauth2-proxy/seamstress.cfg')
            .with(owner: 'root', group: 'oauth2-proxy', mode: '0640')
            .that_notifies('Service[seamstress-oauth2-proxy.service]')
        end

        it 'writes the client secret with no trailing newline' do
          file = catalogue.resource('File', '/etc/oauth2-proxy/client_secret')
          expect(file[:content]).to eq('s3cret')
          expect(file[:owner]).to eq('root')
          expect(file[:group]).to eq('oauth2-proxy')
          expect(file[:mode]).to eq('0640')
          expect(file[:show_diff]).to be(false)
        end

        it 'makes the cookie secret on the node and keeps it out of the catalogue' do
          expect(catalogue).to contain_exec('oauth2-proxy cookie secret').with(
            command: 'head -c 32 /dev/urandom > /etc/oauth2-proxy/cookie_secret',
            umask: '027',
            creates: '/etc/oauth2-proxy/cookie_secret'
          )
          file = catalogue.resource('File', '/etc/oauth2-proxy/cookie_secret')
          expect(file.to_hash.keys).to contain_exactly(:ensure, :owner, :group, :mode, :require, :path)
          expect(file[:group]).to eq('oauth2-proxy')
          expect(file[:mode]).to eq('0640')
        end

        it 'runs oauth2-proxy as its own user in a hardened unit' do
          expect(proxy_unit[:enable]).to be(true)
          expect(proxy_unit[:active]).to be(true)
          expect(proxy_unit[:service_entry]).to include(
            'User' => 'oauth2-proxy', 'Group' => 'oauth2-proxy',
            'ExecStart' => "/opt/oauth2-proxy/#{release}/oauth2-proxy --config=/etc/oauth2-proxy/seamstress.cfg",
            'Restart' => 'on-failure',
            'NoNewPrivileges' => true, 'ProtectSystem' => 'strict', 'ProtectHome' => true,
            'PrivateTmp' => true, 'PrivateDevices' => true, 'ProtectKernelTunables' => true,
            'ProtectKernelModules' => true, 'ProtectControlGroups' => true,
            'RestrictAddressFamilies' => %w[AF_INET AF_INET6 AF_UNIX],
            'CapabilityBoundingSet' => '', 'LockPersonality' => true, 'MemoryDenyWriteExecute' => true
          )
        end

        it 'renders the unit file' do
          unit = catalogue.resource('File', '/etc/systemd/system/seamstress-oauth2-proxy.service')[:content]
          expect(unit).to include("User=oauth2-proxy\n", "CapabilityBoundingSet=\n", "RestrictAddressFamilies=AF_INET6\n",
                                  "MemoryDenyWriteExecute=true\n")
        end

        it 'checks every request with oauth2-proxy' do
          expect(nginx_conf).to include(
            "  auth_request /oauth2/auth;\n  error_page 401 = @oauth2_signin;\n",
            'proxy_pass       http://127.0.0.1:4180;',
            'proxy_set_header X-Forwarded-Proto       https;',
            'proxy_set_header X-Auth-Request-Redirect $request_uri;',
            'proxy_set_header Content-Length    "";',
            'proxy_pass_request_body            off;',
            'return 302 /oauth2/sign_in?rd=$request_uri;'
          )
          expect(nginx_conf.scan('auth_request off;').size).to eq(2)
          expect(nginx_conf).to match(%r{location /oauth2/ \{\n    auth_request off;})
          expect(nginx_conf).to match(%r{location = /oauth2/auth \{\n    auth_request off;})
          expect(nginx_conf).not_to include('auth_basic')
        end

        it 'keeps the security headers on the oauth2-proxy pages' do
          block = nginx_conf[%r{location /oauth2/ \{.*?\n  \}}m]
          expect(block).to include("form-action 'self'", "script-src 'self';", 'nosniff', 'Strict-Transport-Security', 'Referrer-Policy')
        end

        it { is_expected.to contain_file('/etc/nginx/seamstress/htpasswd').with_ensure('absent') }
      end

      context 'when auth is oidc on arm64' do
        let(:facts) { with_arch(os_facts, debian ? 'arm64' : 'aarch64') }
        let(:params) { oidc_params }

        it {
          is_expected.to contain_file('/opt/oauth2-proxy/oauth2-proxy-v7.15.6.linux-arm64.tar.gz').with(
            source: 'https://github.com/oauth2-proxy/oauth2-proxy/releases/download/v7.15.6/oauth2-proxy-v7.15.6.linux-arm64.tar.gz',
            checksum_value: '3593e50daa517eaa8f8d0966b95786a61a4cdf491694dc9091b8cd32daa85d56'
          )
        }
      end

      context 'when auth is oidc on an architecture with no checksum' do
        let(:facts) { with_arch(os_facts, 'ppc64le') }
        let(:params) { oidc_params }

        it { is_expected.to compile.and_raise_error(/no checksum for architecture ppc64le/) }
      end

      context 'when auth is oidc with everything set' do
        let(:params) do
          oidc_params.merge(
            port: 8443, server_name: 'strings.example.com',
            oidc_allowed_groups: ['puppet-admins', 'EXAMPLE\\docs'],
            oidc_email_domains: ['example.com'],
            oidc_scope: 'openid email groups',
            oidc_groups_claim: 'roles',
            oidc_provider_ca_file: '/etc/pki/ca-trust/source/anchors/corp.pem',
            oauth2_proxy_version: '7.16.0',
            oauth2_proxy_checksums: { 'amd64' => 'a' * 64 },
            oauth2_proxy_download_base: 'https://mirror.example.com/oauth2-proxy',
            oauth2_proxy_port: 4999
          )
        end

        it { is_expected.to compile.with_all_deps }

        it 'writes the configuration' do
          expect(proxy_config).to include(
            'redirect_url = "https://strings.example.com:8443/oauth2/callback"',
            'http_address = "127.0.0.1:4999"',
            'allowed_groups = ["puppet-admins","EXAMPLE\\\\docs"]',
            'email_domains = ["example.com"]',
            'scope = "openid email groups"',
            'oidc_groups_claim = "roles"',
            'provider_ca_files = ["/etc/pki/ca-trust/source/anchors/corp.pem"]'
          )
        end

        it {
          is_expected.to contain_file('/opt/oauth2-proxy/oauth2-proxy-v7.16.0.linux-amd64.tar.gz').with(
            source: 'https://mirror.example.com/oauth2-proxy/v7.16.0/oauth2-proxy-v7.16.0.linux-amd64.tar.gz',
            checksum_value: 'a' * 64
          )
        }

        it { expect(nginx_conf).to include('proxy_pass       http://127.0.0.1:4999;') }
      end

      context 'when the client secret is Deferred' do
        let(:params) { oidc_params.merge(oidc_client_secret: deferred("Deferred('join', [['deferred', 'secret'], '-'])")) }

        it { is_expected.to compile.with_all_deps }

        # rspec-puppet resolves Deferred values the way the agent does, so a
        # built-in function stands in for node_decrypt or a Vault lookup.
        it 'writes what the agent resolves into the file' do
          expect(catalogue.resource('File', '/etc/oauth2-proxy/client_secret')[:content]).to eq('deferred-secret')
        end
      end

      context 'with the certificate and key as content' do
        let(:pem) { "-----BEGIN CERTIFICATE-----\nMIIB\n-----END CERTIFICATE-----\n\n" }
        let(:key) { "-----BEGIN PRIVATE KEY-----\nMIIE\n-----END PRIVATE KEY-----\n" }
        let(:params) { git_params.merge(tls_cert: pem, tls_key: sensitive(key)) }

        it { is_expected.to compile.with_all_deps }

        it {
          is_expected.to contain_file('/etc/nginx/seamstress/cert.pem')
            .with(content: "-----BEGIN CERTIFICATE-----\nMIIB\n-----END CERTIFICATE-----\n", source: nil)
        }

        it 'writes the key from Sensitive content' do
          file = catalogue.resource('File', '/etc/nginx/seamstress/key.pem')
          expect(file[:content]).to eq(key)
          expect(file[:source]).to be_nil
          expect(file[:mode]).to eq('0600')
        end
      end

      context 'with the key Deferred' do
        let(:params) { git_params.merge(tls_key: deferred("Deferred('join', [['deferred', 'secret'], '-'])")) }

        it { is_expected.to compile.with_all_deps }

        it 'writes what the agent resolves into the file' do
          file = catalogue.resource('File', '/etc/nginx/seamstress/key.pem')
          expect(file[:source]).to be_nil
          expect(file[:content]).to eq('deferred-secret')
        end
      end
    end
  end
end
