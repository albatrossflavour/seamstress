# frozen_string_literal: true

require_relative 'app_helper'

describe 'strings_site build script helpers' do
  include AppHelper

  describe StringsSite::Environments do
    it 'turns branch names into environment names the way r10k does' do
      expect(described_class.name_for('feature/new-thing')).to eq('feature_new_thing')
      expect(described_class.name_for('production')).to eq('production')
    end

    it 'applies the allow list, then the exclude patterns' do
      names = %w[production development feature_a tmp_build_1]
      expect(described_class.select(names, [], [])).to eq(names)
      expect(described_class.select(names, %w[production development], [])).to eq(%w[production development])
      expect(described_class.select(names, [], ['^feature_', '^tmp_'])).to eq(%w[production development])
      expect(described_class.select(names, %w[production feature_a], ['^feature_'])).to eq(%w[production])
    end

    it 'puts production first' do
      expect(described_class.sort(%w[alpha production development])).to eq(%w[production alpha development])
    end
  end

  describe StringsSite::Puppetfile do
    let(:pf) do
      described_class.parse(<<~PUPPETFILE)
        forge 'https://forge.example.com'
        moduledir 'thirdparty'
        mod 'puppetlabs/stdlib', '9.7.0'
        mod 'puppet-systemd', :latest
        mod 'puppetlabs-concat'
        mod 'app', git: 'git@git.example.com:puppet/app.git', branch: 'main'
        mod 'pinned', :git => 'https://git.example.com/pinned.git', :commit => '#{'a' * 40}'
        mod 'tagged', git: 'https://git.example.com/tagged.git', tag: 'v1.0.0'
        mod 'tracking', git: 'https://git.example.com/t.git', branch: :control_branch, default_branch: 'main'
        mod 'inrepo', local: true
        something_r10k_knows 'x'
      PUPPETFILE
    end

    it 'reads the forge and moduledir' do
      expect(pf.forge_url).to eq('https://forge.example.com')
      expect(pf.moduledir).to eq('thirdparty')
    end

    it 'classifies every module and keeps its declared ref' do
      got = pf.mods.to_h { |m| [m.name, [m.type, m.declared_ref]] }
      expect(got).to eq(
        'stdlib' => [:forge, '9.7.0'], 'systemd' => [:forge, 'latest'], 'concat' => [:forge, 'latest'],
        'app' => [:git, 'main'], 'pinned' => [:git, 'a' * 40], 'tagged' => [:git, 'v1.0.0'],
        'tracking' => [:git, 'control_branch'], 'inrepo' => [:local, 'local']
      )
      expect(pf.mods.find { |m| m.name == 'systemd' }.slug).to eq('puppet-systemd')
    end

    it 'reports a Puppetfile that does not parse' do
      expect { described_class.parse("mod 'x',\n", 'Puppetfile') }.to raise_error(StringsSite::Error, /cannot parse Puppetfile/)
    end
  end

  describe 'StringsSite::Git.resolve_ref' do
    let(:refs) do
      {
        'HEAD' => '1' * 40, 'refs/heads/main' => '1' * 40, 'refs/tags/v1' => '2' * 40, 'refs/tags/v1^{}' => '3' * 40,
        'refs/tags/light' => '4' * 40
      }
    end

    it 'resolves branches, peeled annotated tags, lightweight tags, and full SHAs' do
      expect(StringsSite::Git.resolve_ref(refs, 'main')).to eq('1' * 40)
      expect(StringsSite::Git.resolve_ref(refs, 'v1')).to eq('3' * 40)
      expect(StringsSite::Git.resolve_ref(refs, 'v1', :tag)).to eq('3' * 40)
      expect(StringsSite::Git.resolve_ref(refs, 'light', :tag)).to eq('4' * 40)
      expect(StringsSite::Git.resolve_ref(refs, 'f' * 40)).to eq('f' * 40)
      expect(StringsSite::Git.resolve_ref(refs, 'v1', :branch)).to be_nil
      expect(StringsSite::Git.resolve_ref(refs, 'missing')).to be_nil
    end
  end

  describe StringsSite::Git do
    let(:git) do
      described_class.new(config('control_repo' => 'x', 'deploy_keys' => {
                                   'git@git.example.com:*' => '/keys/host',
                                   'git@git.example.com:puppet/secret.git' => '/keys/secret'
                                 }))
    end

    it 'picks the most specific matching key' do
      expect(git.key_for('git@git.example.com:puppet/secret.git')).to eq('/keys/secret')
      expect(git.key_for('git@git.example.com:puppet/other.git')).to eq('/keys/host')
      expect(git.key_for('https://elsewhere.example.com/x.git')).to be_nil
    end

    it 'passes the key to ssh only for matching remotes and never prompts' do
      env = git.env_for('git@git.example.com:puppet/secret.git')
      expect(env['GIT_SSH_COMMAND']).to include('-i /keys/secret', 'IdentitiesOnly=yes', 'BatchMode=yes')
      expect(env['GIT_TERMINAL_PROMPT']).to eq('0')
      expect(git.env_for('https://elsewhere.example.com/x.git')['GIT_SSH_COMMAND']).not_to include('-i ')
    end
  end

  describe 'StringsSite.redact' do
    it 'removes credentials from URLs' do
      expect(StringsSite.redact('fetch https://user:token@git.example.com/x.git failed'))
        .to eq('fetch https://***@git.example.com/x.git failed')
      expect(StringsSite.redact('git@git.example.com:puppet/x.git')).to eq('git@git.example.com:puppet/x.git')
    end
  end

  describe StringsSite::Config do
    it 'requires a control repo in git mode' do
      expect { described_class.new('source' => 'git') }.to raise_error(StringsSite::Error, /control_repo/)
    end

    it 'requires code_dir or tarballs in directory mode' do
      expect { described_class.new('source' => 'directory') }.to raise_error(StringsSite::Error, /code_dir/)
    end

    it 'rejects an unknown source' do
      expect { described_class.new('source' => 'svn') }.to raise_error(StringsSite::Error, /unknown source/)
    end
  end

  describe 'StringsSite::Forge.api_base' do
    it 'maps the Forge web host to its API host' do
      expect(StringsSite::Forge.api_base('https://forge.puppet.com')).to eq('https://forgeapi.puppet.com')
      expect(StringsSite::Forge.api_base('forge.puppetlabs.com')).to eq('https://forgeapi.puppet.com')
      expect(StringsSite::Forge.api_base('https://forge.example.com/')).to eq('https://forge.example.com')
    end
  end
end
