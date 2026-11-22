# frozen_string_literal: true

require 'cgi'
require_relative '../../../files/app/lib/markdown'

describe StringsSite::Highlight do
  def hl(code, lang) = described_class.html(code, lang)

  it 'marks Puppet keywords, strings with interpolation, variables, types, attributes, and comments' do
    html = hl(%(class { 'a': x => "v${b}", y => Integer } # c\n$z = foo(1)), 'puppet')
    expect(html).to include('<span class="hl-kw">class</span>', '<span class="hl-str">&#39;a&#39;</span>',
                            '<span class="hl-key">x</span>', '<span class="hl-str">&quot;v<span class="hl-var">${b}</span>&quot;</span>',
                            '<span class="hl-typ">Integer</span>', '<span class="hl-com"># c</span>',
                            '<span class="hl-var">$z</span>', '<span class="hl-fn">foo</span>', '<span class="hl-num">1</span>')
  end

  it 'marks Ruby, YAML, JSON, and shell' do
    expect(hl("def a(:b) # x\nend", 'ruby')).to include('<span class="hl-kw">def</span>', '<span class="hl-sym">:b</span>', 'hl-com')
    expect(hl("key: 'v' # c\nn: true", 'yml')).to include('<span class="hl-key">key</span>', '<span class="hl-kw">true</span>', 'hl-com')
    expect(hl('{"a": [1, null]}', 'json')).to include('<span class="hl-key">&quot;a&quot;</span>', '<span class="hl-kw">null</span>')
    expect(hl('bolt task run x --targets $T # go',
              'bash')).to include('<span class="hl-fn">bolt</span>', '<span class="hl-opt">--targets</span>',
                                  '<span class="hl-var">$T</span>', 'hl-com')
  end

  it 'escapes everything, in every language and in none' do
    %w[puppet ruby yaml json shell nonsense].each do |lang|
      html = hl(%(<script>"</script>" '<img onerror=x>' # <b>), lang)
      expect(html).not_to match(%r{<(?!/?span)})
    end
  end

  it 'keeps the text intact' do
    code = File.read(__FILE__)
    expect(CGI.unescapeHTML(hl(code, 'ruby').gsub(/<[^>]+>/, ''))).to eq(code)
  end

  it 'knows the usual names for each language' do
    expect(%w[pp epp rb yml json sh console bash].map do |l|
      described_class.language(l)
    end).to eq(%w[puppet puppet ruby yaml json shell shell shell])
    expect(described_class.language('cobol')).to be_nil
  end
end
