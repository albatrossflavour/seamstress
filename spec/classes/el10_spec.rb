# frozen_string_literal: true

require 'spec_helper'

# metadata.json says EL 10, and FacterDB has no EL 10 facts yet, so
# on_supported_os skips it and nothing else here compiles the class for it.
# These take each EL 9 fact set with the release moved on, which is all the
# module looks at: it branches on the OS family and the architecture.
describe 'seamstress' do
  el9 = [{ 'operatingsystem' => 'RedHat', 'operatingsystemrelease' => ['9'] },
         { 'operatingsystem' => 'Rocky', 'operatingsystemrelease' => ['9'] },
         { 'operatingsystem' => 'AlmaLinux', 'operatingsystemrelease' => ['9'] },
         { 'operatingsystem' => 'OracleLinux', 'operatingsystemrelease' => ['9'] }]

  on_supported_os(supported_os: el9).each do |os, os_facts|
    context "when on #{os.sub('-9-', '-10-')}" do
      let(:node) { 'docs.example.com' }
      let(:facts) do
        release = { 'major' => '10', 'minor' => '0', 'full' => '10.0' }
        os_facts.merge(os: os_facts[:os].merge('release' => release), operatingsystemmajrelease: '10', operatingsystemrelease: '10.0')
      end
      let(:params) do
        {
          control_repo: 'git@git.example.com:puppet/control-repo.git', auth: 'oidc',
          oidc_issuer_url: 'https://login.example.com/realms/staff', oidc_client_id: 'seamstress', oidc_client_secret: sensitive('s3cret')
        }
      end

      it { is_expected.to compile.with_all_deps }
      it { is_expected.to contain_systemd__manage_unit('seamstress.service') }
      it { is_expected.to contain_systemd__manage_unit('seamstress-oauth2-proxy.service').with_ensure('present') }
      it { is_expected.to contain_file('/etc/nginx/conf.d/seamstress.conf') }
    end
  end
end
