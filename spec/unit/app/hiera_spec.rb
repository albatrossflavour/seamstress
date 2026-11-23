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

  context 'when hiera.yaml leaves out what Puppet has defaults for' do
    let(:one_level) { "hierarchy:\n  - name: All\n    path: common.yaml\n" }

    it 'reads yaml_data files under data when there is no defaults block' do
      write(File.join(root, 'hiera.yaml'), "---\nversion: 5\nhierarchy:\n  - name: Everything\n    path: common.yaml\n")
      expect(index['levels']).to eq([{ 'name' => 'Everything', 'backend' => 'yaml_data', 'datadir' => 'data', 'path' => 'common.yaml',
                                       'vars' => [], 'files' => [{ 'file' => 'data/common.yaml', 'vars' => {}, 'keys' => 4 }],
                                       'readable' => true }])
    end

    it 'reads a single common.yaml level, named Common, when there is no hierarchy' do
      write(File.join(root, 'hiera.yaml'), "---\nversion: 5\n")
      expect(index['levels'].map { |l| l.values_at('name', 'path', 'backend', 'datadir', 'readable') }).to eq(
        [['Common', 'common.yaml', 'yaml_data', 'data', true]]
      )
      expect(Seamstress::HieraFiles.datadirs("---\nversion: 5\n")).to eq(['data'])
    end

    it 'takes data as the datadir when the defaults block names only a backend' do
      write(File.join(root, 'hiera.yaml'), "---\nversion: 5\ndefaults:\n  data_hash: yaml_data\n#{one_level}")
      expect(index['levels'][0]).to include('datadir' => 'data', 'readable' => true)
    end

    # Puppet fails the whole configuration for this, so there is no default
    # to fall back to.
    it 'cannot read a level when neither it nor a defaults block that is there names a backend' do
      write(File.join(root, 'hiera.yaml'), "---\nversion: 5\ndefaults:\n  datadir: data\n#{one_level}")
      expect(index['levels'][0]).to include('readable' => false, 'backend' => '',
                                            'reason' => 'no backend is named for it or in defaults, which Puppet refuses')
    end

    it 'does not read a level with a Hiera 3 backend as if it had the default one' do
      write(File.join(root, 'hiera.yaml'), "---\nversion: 5\n#{one_level}    hiera3_backend: consul\n")
      expect(index['levels'][0]).to include('readable' => false, 'reason' => 'the consul backend is not read')
    end
  end

  context 'when ciphertext is not the whole of a value' do
    before do
      data('role/role::db.yaml', <<~YAML)
        ---
        app::dsn: "postgres://app:ENC[PKCS7,MIIBdsn]@db/x"
        app::list: ["x ENC[GPG,hQIMAlist]", plain]
        app::kms: ENC[KMS,AQICAHkms]
        app::block: |
          first ENC[PKCS7,MIIBblock
          MIIBsplit]
        app::unclosed: "ENC[PKCS7,MIIBunclosed"
        app::nested:
          "ENC[PKCS7,MIIBkeyone]": 1
          "ENC[PKCS7,MIIBkeytwo]": 2
        "ENC[PKCS7,MIIBtop]": top
      YAML
      data('os/RedHat.yaml', "---\n\"ENC[PKCS7,MIIBtop]\": other\n")
    end

    let(:db) { index['data']['data/role/role::db.yaml'] }

    it 'publishes no eyaml block anywhere in the index, nor the text around one' do
      json = JSON.generate(index)
      expect(json).not_to include('ENC[')
      expect(json).not_to include('MIIB', 'hQIMA', 'AQICAH', 'postgres://app', '@db/x', 'x ENC', 'first')
    end

    it 'replaces a string that holds ciphertext anywhere, whatever the method and across lines' do
      expect(db.values_at('app::dsn', 'app::kms', 'app::block', 'app::unclosed')).to all(eq('__enc' => true))
      expect(db['app::list']).to eq([{ '__enc' => true }, 'plain'])
    end

    it 'renames a key that is ciphertext, keeping its value and keeping two such keys apart' do
      names = db['app::nested'].keys
      expect(names).to all(match(/\Aencrypted key \h{8}\z/))
      expect(names.uniq.size).to eq(2)
      expect(db['app::nested'].values).to eq([1, 2])
    end

    it 'gives the same ciphertext key the same name in every file' do
      top = db.keys.grep(/\Aencrypted key/)
      expect(top.size).to eq(1)
      expect(db[top.first]).to eq('top')
      expect(index['data']['data/os/RedHat.yaml']).to eq(top.first => 'other')
    end

    it 'gives a ciphertext key a longer name sooner than the one another key has' do
      taken = "encrypted key #{Digest::SHA256.hexdigest('ENC[PKCS7,MIIBclash]')[0, 8]}"
      data('role/role::db.yaml', "---\n\"ENC[PKCS7,MIIBclash]\": 1\n\"#{taken}\": 2\n")
      expect(db.keys).to contain_exactly(a_string_matching(/\Aencrypted key \h{9}\z/), taken)
    end
  end

  context 'when a data file is a link' do
    let(:outside) { File.join(tmp, 'outside') }

    before do
      write(File.join(outside, 'config.yaml'), "---\nleaked::secret: hunter2\n")
      write(File.join(outside, 'inner/common.yaml'), "---\nleaked::dir: hunter3\n")
    end

    it 'does not read a file that links out of the environment, and notes it' do
      File.symlink(File.join(outside, 'config.yaml'), File.join(root, 'data/node/leak.yaml'))
      expect(JSON.generate(index)).not_to include('hunter2', 'leaked::secret')
      expect(index['data']).not_to have_key('data/node/leak.yaml')
      expect(index['levels'][0]['files']).to eq([])
      expect(index['notes']).to include('data/node/leak.yaml is a link or lies outside the environment, so it is not read.')
    end

    it 'does not read a file that links to another inside the environment either' do
      File.symlink(File.join(root, 'data/common.yaml'), File.join(root, 'data/node/twin.yaml'))
      expect(index['data']).not_to have_key('data/node/twin.yaml')
      expect(index['notes'].grep(%r{data/node/twin.yaml is a link}).size).to eq(1)
    end

    it 'does not read files under a directory that links out of the environment' do
      File.symlink(File.join(outside, 'inner'), File.join(root, 'data/group'))
      write(File.join(root, 'hiera.yaml'), "---\nversion: 5\nhierarchy:\n  - name: Group\n    path: group/common.yaml\n")
      expect(JSON.generate(index)).not_to include('hunter3')
      expect(index['levels'][0]['files']).to eq([])
    end

    it 'cannot read a level whose datadir links out of the environment, and notes it' do
      File.symlink(File.join(outside, 'inner'), File.join(root, 'elsewhere'))
      write(File.join(root, 'hiera.yaml'), "---\nversion: 5\nhierarchy:\n  - name: Away\n    datadir: elsewhere\n    path: common.yaml\n")
      expect(JSON.generate(index)).not_to include('hunter3')
      expect(index['levels'][0]).to include('readable' => false, 'files' => [], 'reason' => 'its datadir links outside the environment')
      expect(index['notes']).to include('The datadir elsewhere links outside the environment, so it is not read.')
    end

    it 'reads a datadir that links to a directory inside the environment' do
      File.symlink(File.join(root, 'data'), File.join(root, 'hieradata'))
      write(File.join(root, 'hiera.yaml'), "---\nversion: 5\nhierarchy:\n  - name: Same\n    datadir: hieradata\n    path: common.yaml\n")
      expect(index['levels'][0]['files'].map { |f| f['file'] }).to eq(['hieradata/common.yaml'])
    end

    it 'fingerprints a link by where it points, without reading what is there' do
      File.symlink(File.join(outside, 'config.yaml'), File.join(root, 'data/node/leak.yaml'))
      File.symlink(File.join(outside, 'inner'), File.join(root, 'data/group'))
      first = Seamstress::HieraFiles.digest(root)
      write(File.join(outside, 'config.yaml'), "---\nleaked::secret: changed\n")
      write(File.join(outside, 'inner/common.yaml'), "---\nleaked::dir: changed\n")
      expect(Seamstress::HieraFiles.digest(root)).to eq(first)
      File.delete(File.join(root, 'data/node/leak.yaml'))
      File.symlink(File.join(outside, 'inner/common.yaml'), File.join(root, 'data/node/leak.yaml'))
      expect(Seamstress::HieraFiles.digest(root)).not_to eq(first)
    end

    it 'fingerprints nothing under a datadir that links out of the environment' do
      File.symlink(File.join(outside, 'inner'), File.join(root, 'elsewhere'))
      write(File.join(root, 'hiera.yaml'), "---\nversion: 5\nhierarchy:\n  - name: Away\n    datadir: elsewhere\n    path: common.yaml\n")
      first = Seamstress::HieraFiles.digest(root)
      write(File.join(outside, 'inner/common.yaml'), "---\nleaked::dir: changed\n")
      expect(Seamstress::HieraFiles.digest(root)).to eq(first)
    end
  end

  context 'when a data file uses YAML anchors' do
    it 'reads ordinary anchors and aliases' do
      data('role/role::db.yaml', <<~YAML)
        ---
        app::base: &base
          user: app
          shell: /bin/sh
        app::copy: *base
        app::more:
          <<: *base
          uid: 5
      YAML
      db = index['data']['data/role/role::db.yaml']
      expect(db['app::copy']).to eq('user' => 'app', 'shell' => '/bin/sh')
      expect(db['app::more']).to eq('user' => 'app', 'shell' => '/bin/sh', 'uid' => 5)
    end

    it 'shows a file whose aliases expand past what the index holds as empty, and notes it' do
      bomb = "---\na0: &a0 [x, x, x, x, x, x, x, x, x, x]\n"
      bomb += (1..9).map { |n| "a#{n}: &a#{n} [#{(["*a#{n - 1}"] * 10).join(', ')}]\n" }.join
      data('role/role::db.yaml', bomb)
      expect(index['data']['data/role/role::db.yaml']).to eq({})
      expect(index['notes']).to include('data/role/role::db.yaml comes to more than the index holds once its aliases are followed, ' \
                                        'so it is shown as empty.')
      expect(JSON.generate(index).size).to be < 100_000
    end

    it 'shows a file where one long string is aliased many times as empty too' do
      data('role/role::db.yaml', "---\nlong: &long #{'x' * 100_000}\nmany: [#{(['*long'] * 5000).join(', ')}]\n")
      expect(index['data']['data/role/role::db.yaml']).to eq({})
    end
  end

  it 'does not offer the name of a file it could not read as a value for a variable' do
    expect(index['levels'][0]['files']).to eq([])
    expect(JSON.generate(index['levels'])).not_to include('broken.example.com')
  end

  it 'leaves keys unmerged, and says so, once the merged values would swell the index' do
    stub_const('Seamstress::HieraMerges::MAX_MERGED', 60)
    expect(index['merged'].size).to be < 2
    expect(index['notes'].join).to include('has merged values that would swell the index, so its merged value is not shown.')
  end

  it 'carries more values to offer for a variable, as sorted strings without repeats or blanks' do
    given = { 'trusted.certname' => ['b.example.com', 'a.example.com', 'b.example.com', ''], :n => [9] }
    extra = described_class.index(root, environment: 'production', values: given)
    expect(extra['values']).to eq('trusted.certname' => ['a.example.com', 'b.example.com'], 'n' => ['9'])
    expect(index['values']).to eq({})
  end

  it 'keeps only the first of more values than the limit, and says so' do
    many = { 'trusted.certname' => %w[d c b a], 'facts.kernel' => %w[Linux windows] }
    cut = described_class.index(root, environment: 'production', values: many, limit: 2)
    expect(cut['values']).to eq('trusted.certname' => %w[a b], 'facts.kernel' => %w[Linux windows])
    expect(cut['notes']).to include('trusted.certname has 4 values, so the first 2 are offered. Any value can still be typed.')
    expect(cut['notes'].grep(/facts\.kernel/)).to be_empty
  end

  it 'carries the named samples as strings, and summarises itself' do
    expect(index['samples']).to eq('A web server' => { 'facts.os.family' => 'RedHat', 'n' => '9' })
    expect(described_class.summary(index)).to eq('levels' => 7, 'files' => 6, 'keys' => 5)
  end

  # What a second review got past the first round of limits.
  context 'when a data file leans on what YAML allows and Hiera has no use for' do
    it 'shows a file empty when a key is a list or a mapping, however small the file' do
      data('os/Odd.yaml', <<~YAML)
        ---
        a: &a [x, x, x, x, x, x, x, x, x, x]
        b: &b [*a, *a, *a, *a, *a, *a, *a, *a, *a, *a]
        ? [*b, *b, *b, *b, *b, *b, *b, *b, *b, *b]
        : v
      YAML
      expect(index['data']['data/os/Odd.yaml']).to eq({})
      expect(index['notes'].join).to include('data/os/Odd.yaml has a key that is a list or a mapping')
    end

    it 'counts a string by its bytes, so many short ones are not free' do
      stub_const('Seamstress::HieraCopy::LIMIT', 2_000)
      data('os/Many.yaml', "---\nwords: &w [#{Array.new(40, 'abcdefghijklmnopqrstuvwxyz').join(', ')}]\nmore: [*w, *w, *w]\n")
      expect(index['data']['data/os/Many.yaml']).to eq({})
      expect(index['notes'].join).to include('data/os/Many.yaml comes to more than the index holds')
    end

    it 'holds every file together to one limit as well as each to its own' do
      stub_const('Seamstress::HieraReader::TOTAL', 60)
      expect(index['data'].values.count(&:empty?)).to be > 1
      expect(index['notes'].grep(/comes to more than the index holds/).size).to be > 1
    end

    it 'carries .inf, .nan, and bytes that are not text as strings JSON can hold' do
      data('os/Awkward.yaml', "---\nup: .inf\nnone: .nan\nraw: !!binary /w==\n")
      awkward = index['data']['data/os/Awkward.yaml']
      expect(awkward).to eq('up' => 'Infinity', 'none' => 'NaN', 'raw' => '?')
      expect { JSON.generate(index) }.not_to raise_error
    end
  end

  it 'shows where a uri level is without the credentials or token in it' do
    write(File.join(root, 'hiera.yaml'), <<~YAML)
      ---
      version: 5
      hierarchy:
        - name: Consul
          lookup_key: consul_lookup
          uri: "https://user:s3cr3tpw@consul.example/v1/kv?token=TOKTOK"
    YAML
    expect(index['levels'][0]['path']).to eq('https://consul.example/v1/kv')
    expect(JSON.generate(index)).not_to include('s3cr3tpw', 'TOKTOK')
  end

  it 'does not follow a hiera.yaml that is a link' do
    elsewhere = File.join(tmp, 'elsewhere.yaml')
    FileUtils.mv(File.join(root, 'hiera.yaml'), elsewhere)
    File.symlink(elsewhere, File.join(root, 'hiera.yaml'))
    expect(index).to be_nil
    expect(Seamstress::HieraFiles.digest(root)).to be_nil
  end
end
