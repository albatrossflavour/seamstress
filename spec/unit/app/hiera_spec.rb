# frozen_string_literal: true

require_relative 'app_helper'

describe Seamstress::Hiera do
  include AppHelper

  let(:root) { File.join(tmp, 'production') }
  let(:hiera_yaml) do
    <<~YAML
      ---
      version: 5
      defaults:
        datadir: data
        data_hash: yaml_data
      hierarchy:
        - name: Secrets and settings
          lookup_key: eyaml_lookup_key
          paths:
            - "node/%{trusted.certname}.yaml"
            - "role/%{trusted.extensions.pp_role}.yaml"
            - "os/%{facts.os.family}-%{facts.os.release.major}.yaml"
            - "os/%{facts.os.family}.yaml"
            - "common.yaml"
        - name: A vault
          lookup_key: vault_lookup
          path: "secret/%{trusted.certname}"
        - name: Globbed
          glob: "extra/*.yaml"
    YAML
  end
  let(:samples) { { 'A web server' => { 'facts.os.family' => 'RedHat', 'n' => 9 } } }
  let(:index) { described_class.index(root, environment: 'production', samples: samples) }

  def data(file, content)
    write(File.join(root, 'data', file), content)
  end

  before do
    write(File.join(root, 'hiera.yaml'), hiera_yaml)
    data('common.yaml', <<~YAML)
      ---
      lookup_options:
        app::settings:
          merge:
            strategy: deep
            merge_hash_arrays: true
        app::admins:
          merge: unique
        "^app::secret":
          convert_to: Sensitive
      app::settings:
        listen: 80
        mounts:
          - path: /srv
      app::admins: [root, ops]
      app::port: 80
      app::secret_token: >
        ENC[PKCS7,MIIBeQYJKoZIhvcNAQcDoIIBajCCAWYCAQAx
        ggEhMIIBHQIBADAFMAACAQAwDQYJKoZIhvcNAQEBBQAE]
    YAML
    data('os/RedHat.yaml', "---\napp::settings:\n  user: apache\napp::admins: [wheel]\n")
    data('os/RedHat-9.yaml', "---\napp::port: 8080\n")
    data('role/role::web.yaml', <<~YAML)
      ---
      app::settings:
        listen: 443
        mounts:
          - mode: ro
      app::admins: [web, root]
      nested:
        token: ENC[PKCS7,abc]
        list: [plain, 'ENC[PKCS7,def]']
    YAML
    data('role/role::db.yaml', "---\napp::admins: [dba]\n")
    data('node/broken.example.com.yaml', "---\n  bad: [unclosed\n")
  end

  it 'is nil without a Hiera 5 configuration' do
    expect(described_class.index(File.join(tmp, 'nowhere'), environment: 'x')).to be_nil
    write(File.join(root, 'hiera.yaml'), "---\nversion: 3\n")
    expect(index).to be_nil
  end

  it 'lists one level per path in order, with its backend and the variables it interpolates' do
    expect(index['levels'].map { |l| l['path'] }).to eq(
      ['node/%{trusted.certname}.yaml', 'role/%{trusted.extensions.pp_role}.yaml', 'os/%{facts.os.family}-%{facts.os.release.major}.yaml',
       'os/%{facts.os.family}.yaml', 'common.yaml', 'secret/%{trusted.certname}', 'extra/*.yaml']
    )
    expect(index['levels'][2]).to include('backend' => 'eyaml_lookup_key', 'datadir' => 'data', 'readable' => true,
                                          'vars' => ['facts.os.family', 'facts.os.release.major'])
    expect(index['levels'][4]['vars']).to eq([])
  end

  it 'gives each level its files, with the variable values their names imply and how many keys they set' do
    role = index['levels'][1]['files']
    expect(role).to eq([
                         { 'file' => 'data/role/role::db.yaml', 'vars' => { 'trusted.extensions.pp_role' => 'role::db' }, 'keys' => 1 },
                         { 'file' => 'data/role/role::web.yaml', 'vars' => { 'trusted.extensions.pp_role' => 'role::web' }, 'keys' => 3 }
                       ])
    expect(index['levels'][2]['files'].map { |f| f['vars'] }).to eq([{ 'facts.os.family' => 'RedHat', 'facts.os.release.major' => '9' }])
    expect(index['levels'][4]['files']).to eq([{ 'file' => 'data/common.yaml', 'vars' => {}, 'keys' => 4 }])
  end

  it 'leaves a file with the more specific of two levels it fits' do
    expect(index['levels'][3]['files'].map { |f| f['file'] }).to eq(['data/os/RedHat.yaml'])
  end

  it 'marks a level it cannot read, and says why' do
    expect(index['levels'][5]).to include('readable' => false, 'files' => [], 'reason' => 'the vault_lookup backend is not read')
    expect(index['levels'][6]).to include('readable' => false, 'reason' => 'glob is not read, only path and paths')
  end

  it 'never carries ciphertext, at any depth' do
    expect(JSON.generate(index)).not_to include('ENC[', 'PKCS7', 'MIIBeQ')
    expect(index['data']['data/common.yaml']['app::secret_token']).to eq('__enc' => true)
    nested = index['data']['data/role/role::web.yaml']['nested']
    expect(nested).to eq('token' => { '__enc' => true }, 'list' => ['plain', { '__enc' => true }])
  end

  it 'shows a file that is not YAML as empty, and notes it' do
    expect(index['data']['data/node/broken.example.com.yaml']).to eq({})
    expect(index['notes'].join).to include('data/node/broken.example.com.yaml could not be read as YAML')
  end

  it 'collects lookup_options' do
    expect(index['lookup_options']).to include(
      'app::settings' => { 'merge' => { 'strategy' => 'deep', 'merge_hash_arrays' => true } },
      'app::admins' => { 'merge' => 'unique' }, '^app::secret' => { 'convert_to' => 'Sensitive' }
    )
  end

  it 'merges as Puppet does, for every set of files that can apply together' do
    merged = index['merged']
    expect(index['notes'].grep(/merged/)).to be_empty
    expect(merged.keys).to contain_exactly('app::settings', 'app::admins')
    expect(merged['app::admins']).to include(
      "data/role/role::web.yaml\ndata/os/RedHat.yaml\ndata/common.yaml" => %w[web root wheel ops],
      "data/role/role::db.yaml\ndata/common.yaml" => %w[dba root ops],
      "data/os/RedHat.yaml\ndata/common.yaml" => %w[wheel root ops]
    )
    expect(merged['app::admins'].keys).not_to include(a_string_matching(/role::web.*role::db|role::db.*role::web/m))
    expect(merged['app::settings']["data/role/role::web.yaml\ndata/os/RedHat.yaml\ndata/common.yaml"]).to eq(
      'listen' => 443, 'user' => 'apache', 'mounts' => [{ 'path' => '/srv', 'mode' => 'ro' }]
    )
  end

  it 'leaves the data files as they were read after merging' do
    index
    expect(index['data']['data/common.yaml']['app::settings']).to eq('listen' => 80, 'mounts' => [{ 'path' => '/srv' }])
  end

  it 'carries more values to offer for a variable, as sorted strings without repeats or blanks' do
    given = { 'trusted.certname' => ['b.example.com', 'a.example.com', 'b.example.com', ''], :n => [9] }
    extra = described_class.index(root, environment: 'production', values: given)
    expect(extra['values']).to eq('trusted.certname' => ['a.example.com', 'b.example.com'], 'n' => ['9'])
    expect(index['values']).to eq({})
  end

  it 'carries the named samples as strings, and summarises itself' do
    expect(index['samples']).to eq('A web server' => { 'facts.os.family' => 'RedHat', 'n' => '9' })
    expect(described_class.summary(index)).to eq('levels' => 7, 'files' => 6, 'keys' => 5)
  end
end
