# frozen_string_literal: true

require_relative 'app_helper'

# A module comes from the Forge or someone else's repository, so nothing in it
# may run code in the build, read a file from outside itself, or stop the run.
describe 'seamstress and a module it does not trust' do
  include AppHelper

  let(:code_dir) { File.join(tmp, 'environments') }
  let(:mod) { File.join(code_dir, 'production', 'modules', 'evil') }
  let(:outside) { File.join(tmp, 'outside') }
  let(:cfg) { config('source' => 'directory', 'code_dir' => code_dir) }
  let(:module_page) { File.read(File.join(tmp, 'www', 'environments', 'production', 'modules', 'evil', 'index.html')) }

  # Stands in for `puppet strings generate`, and records what it was handed.
  def recording_puppet
    path = File.join(tmp, 'bin', 'puppet')
    write(path, <<~SH)
      #!/bin/sh
      find . | sort > '#{tmp}/handed'
      echo "$HOME" > '#{tmp}/home'
      printf '{"puppet_classes":[]}' > "$6"
    SH
    File.chmod(0o755, path)
  end

  def handed
    File.read(File.join(tmp, 'handed')).split("\n")
  end

  def evil
    build_json('production')['modules'].find { |m| m['name'] == 'evil' }
  end

  before do
    recording_puppet
    write(File.join(mod, 'manifests/init.pp'), manifest('evil'))
    write(File.join(outside, 'README.md'), 'TOP SECRET')
    write(File.join(outside, 'metadata.json'), JSON.generate('version' => '6.6.6', 'summary' => 'TOP SECRET'))
  end

  it 'does not hand puppet strings a .yardopts or a .document, which YARD takes options such as --load from' do
    write(File.join(mod, '.yardopts'), "--load evil.rb\n")
    write(File.join(mod, '.document'), "--load evil.rb\n")
    expect(run_app(cfg)).to eq(0)
    expect(handed).to include('./manifests/init.pp')
    expect(handed).not_to include('./.yardopts', './.document')
  end

  it 'does not publish a README that is a symlink to a file outside the module' do
    File.symlink(File.join(outside, 'README.md'), File.join(mod, 'README.md'))
    expect(run_app(cfg)).to eq(0)
    expect(handed).not_to include('./README.md')
    expect(module_page).not_to include('TOP SECRET')
  end

  it 'does not copy a top-level symlink to a directory outside the module' do
    File.symlink(outside, File.join(mod, 'files'))
    run_app(cfg)
    expect(handed.grep(%r{\A\./files})).to be_empty
  end

  it 'removes every symlink below the top before puppet strings runs' do
    File.symlink(File.join(outside, 'README.md'), File.join(mod, 'manifests', 'leak.pp'))
    File.symlink(outside, File.join(mod, 'manifests', 'more'))
    run_app(cfg)
    expect(handed).to include('./manifests/init.pp')
    expect(handed.grep(/leak|more/)).to be_empty
  end

  it 'takes nothing from a metadata.json that is a symlink' do
    File.symlink(File.join(outside, 'metadata.json'), File.join(mod, 'metadata.json'))
    run_app(cfg)
    expect(evil).to include('status' => 'ok', 'version' => nil)
    expect(module_page).not_to include('TOP SECRET')
  end

  it 'never gives puppet strings the module as its HOME, where Puppet and YARD read their settings' do
    home = ENV.delete('HOME')
    run_app(cfg)
    expect(File.read(File.join(tmp, 'home')).strip).to end_with('evil.strings.home')
    expect(handed).not_to be_empty
  ensure
    ENV['HOME'] = home
  end

  it 'builds a README nested deeper than the stack would take, and finishes the run' do
    write(File.join(mod, 'README.md'), "# Evil\n\n#{'>' * 5000} deep\n")
    expect(run_app(cfg)).to eq(0)
    expect(evil['status']).to eq('ok')
    expect(module_page).to include('deep')
    expect(status['last_success']).not_to be_nil
  end
end
