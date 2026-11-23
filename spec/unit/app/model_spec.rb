# frozen_string_literal: true

require_relative 'app_helper'

describe 'seamstress documentation model' do
  def obj(kind, data, mod = 'webapp')
    Seamstress::Docs::Obj.new(Seamstress::Docs::KIND_BY_KEY.fetch(kind), mod, data)
  end

  def tags(*list) = { 'text' => '', 'tags' => list }

  describe Seamstress::Docs::Obj do
    it 'takes the summary tag, or the first paragraph when there is none' do
      expect(obj('puppet_classes', 'name' => 'a', 'docstring' => tags({ 'tag_name' => 'summary', 'text' => ' S ' })).summary).to eq('S')
      expect(obj('puppet_classes', 'name' => 'a', 'docstring' => { 'text' => "First.\n\nSecond." }).summary).to eq('First.')
    end

    it 'counts a summary and each parameter description towards coverage' do
      o = obj('puppet_classes', 'name' => 'a', 'defaults' => { 'y' => '1' },
                                'docstring' => tags({ 'tag_name' => 'param', 'name' => 'x', 'text' => 'X.' },
                                                    { 'tag_name' => 'param', 'name' => 'y', 'text' => '' }))
      expect(o.coverage_items).to eq([['summary', false], ['$x', true], ['$y', false]])
      expect(o.missing).to eq(%w[summary $y])
      expect(o.params.map { |p| [p[:name], p[:required], p[:default]] }).to eq([['x', true, nil], ['y', false, '1']])
    end

    it 'leaves the automatic provider parameter out of coverage' do
      o = obj('resource_types', 'name' => 't', 'docstring' => tags({ 'tag_name' => 'summary', 'text' => 'T' }),
                                'parameters' => [{ 'name' => 'provider', 'description' => '' },
                                                 { 'name' => 'name', 'isnamevar' => true, 'description' => 'N' }])
      expect(o.coverage_items).to eq([['summary', true], ['$name', true]])
    end

    it 'counts function signature parameters' do
      o = obj('puppet_functions', 'name' => 'f', 'docstring' => tags,
                                  'signatures' => [{ 'signature' => 'f(String $a)',
                                                     'docstring' => tags({ 'tag_name' => 'param', 'name' => 'a', 'text' => '' }) }])
      expect(o.coverage_items).to eq([['summary', false], ['$a', false]])
    end

    it 'names tasks after their module, init after the module itself, and providers after their type' do
      expect(obj('puppet_tasks', 'name' => 'restart').name).to eq('webapp::restart')
      expect(obj('puppet_tasks', 'name' => 'init').name).to eq('webapp')
      expect(obj('providers', 'name' => 'cli', 'type_name' => 'webapp_site').name).to eq('webapp_site/cli')
    end

    it 'turns names into safe file names that cannot collide' do
      expect(obj('puppet_classes', 'name' => 'a::b_c').url).to eq('modules/webapp/classes/a.b_c.html')
      expect(obj('puppet_classes', 'name' => 'a_b::c').file_name).not_to eq(obj('puppet_classes', 'name' => 'a::b_c').file_name)
      expect(obj('puppet_classes', 'name' => '../../x').file_name).to eq('..-..-x.html') # no slash, so it stays in its directory
    end
  end

  describe Seamstress::Docs::Environment do
    let(:env) do
      mods = {
        'webapp' => { 'puppet_classes' => [{ 'name' => 'webapp', 'docstring' => tags,
                                             'source' => <<~PP }],
                                               class webapp(Webapp::Port $p) {
                                                 include profile::base # include ignored::comment
                                                 webapp_site { 'x': }
                                                 $v = upcase('a')
                                               }
                                             PP
                      'resource_types' => [{ 'name' => 'webapp_site', 'docstring' => tags }],
                      'data_type_aliases' => [{ 'name' => 'Webapp::Port', 'docstring' => tags, 'alias_of' => 'Integer' }] },
        'profile' => { 'puppet_classes' => [{ 'name' => 'profile::base', 'docstring' => tags }],
                       'puppet_functions' => [{ 'name' => 'upcase', 'docstring' => tags }] }
      }
      described_class.new(mods.map { |n, d| Seamstress::Docs::Mod.new({ 'name' => n, 'status' => 'ok' }, d, {}, nil) })
    end

    it 'looks objects up as Puppet code would name them' do
      expect(env.lookup('profile::base').name).to eq('profile::base')
      expect(env.lookup('::profile::base').name).to eq('profile::base')
      expect(env.lookup("Class['profile::base']").name).to eq('profile::base')
      expect(env.lookup('upcase()').name).to eq('upcase')
      expect(env.lookup('Webapp::Port').name).to eq('Webapp::Port')
      expect(env.lookup('webapp::port')).to be_nil # types are case-sensitive
      expect(env.lookup('nothing')).to be_nil
    end

    it 'finds includes, resource declarations, function calls, and types in source, not in comments' do
      expect(env.uses(env.lookup('webapp')).map(&:name)).to eq(%w[profile::base webapp_site upcase Webapp::Port])
      expect(env.used_by(env.lookup('profile::base')).map(&:name)).to eq(%w[webapp])
    end
  end

  describe 'Seamstress::Docs.coverage' do
    it 'rounds down and treats nothing to document as complete' do
      expect(Seamstress::Docs.coverage([['a', true], ['b', true], ['c', false]])).to eq('documented' => 2, 'total' => 3, 'percent' => 66)
      expect(Seamstress::Docs.coverage([])).to eq('documented' => 0, 'total' => 0, 'percent' => 100)
    end
  end

  describe 'Seamstress::Docs.diff' do
    let(:left) do
      { 'a' => { 'version' => '1', 'sha' => 'x' }, 'b' => { 'version' => '1', 'sha' => 'y' },
        'c' => { 'ref' => 'main', 'sha' => 'z' }, 'gone' => { 'version' => '1' } }
    end
    let(:right) do
      { 'a' => { 'version' => '1', 'sha' => 'x' }, 'b' => { 'version' => '2', 'sha' => 'y2' },
        'c' => { 'ref' => 'main', 'sha' => 'z2' }, 'new' => { 'version' => '1' } }
    end

    it 'sorts modules into changed, with the fields that moved, added, removed, and the same' do
      expect(Seamstress::Docs.diff(left, right)).to eq(
        'changed' => { 'b' => %w[version sha], 'c' => ['sha'] }, 'added' => ['new'], 'removed' => ['gone'], 'same' => ['a']
      )
    end

    it "ignores a control-repo module's ref, which is the control repo's commit" do
      l = { 'role' => { 'kind' => 'control', 'ref' => 'aaa', 'sha' => 't1' }, 'git' => { 'kind' => 'git', 'ref' => 'v1', 'sha' => 's' } }
      r = { 'role' => { 'kind' => 'control', 'ref' => 'bbb', 'sha' => 't1' }, 'git' => { 'kind' => 'git', 'ref' => 'v2', 'sha' => 's' } }
      expect(Seamstress::Docs.diff(l, r)).to include('changed' => { 'git' => ['ref'] }, 'same' => ['role'])
    end

    it 'finds nothing between an environment and itself' do
      expect(Seamstress::Docs.diff(left, left)).to include('changed' => {}, 'added' => [], 'removed' => [])
    end

    it 'reads modules from a build manifest' do
      manifest = { 'modules' => [{ 'name' => 'a', 'version' => '1', 'sha' => 's', 'status' => 'ok', 'counts' => {} }] }
      expect(Seamstress::Docs.module_map(manifest)).to eq('a' => { 'version' => '1', 'sha' => 's', 'status' => 'ok' })
      expect(Seamstress::Docs.module_map(nil)).to eq({})
    end
  end
end
