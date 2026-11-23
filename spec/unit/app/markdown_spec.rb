# frozen_string_literal: true

require_relative '../../../files/app/lib/markdown'

describe Seamstress::Markdown do
  def md(text, **)
    described_class.render(text, **)
  end

  def inline(text) = described_class.new.inline(text)

  describe 'blocks' do
    it 'renders headings one level down, with an anchor id and link' do
      expect(md('# Usage')).to eq('<h2 id="md-usage">Usage<a class="anchor" href="#md-usage" aria-label="Link to this section">#</a></h2>')
      expect(md("Title\n=====")).to start_with('<h2 id="md-title">')
      expect(md('## Usage', heading_prefix: 'readme-', heading_offset: 2)).to start_with('<h4 id="readme-usage">')
    end

    it 'keeps heading ids unique' do
      expect(md("# A\n\n# A")).to include('id="md-a"', 'id="md-a-2"')
    end

    it 'renders paragraphs, rules, and block quotes with lazy continuation' do
      expect(md("one\ntwo\n\nthree")).to eq("<p>one\ntwo</p>\n<p>three</p>")
      expect(md('---')).to eq('<hr>')
      expect(md("> *Note:*\n  since Puppet 5")).to eq("<blockquote>\n<p><em>Note:</em>\nsince Puppet 5</p>\n</blockquote>")
    end

    it 'renders lists, nested and ordered' do
      expect(md("- a\n- b\n  - c")).to eq("<ul>\n<li>a</li>\n<li>b\n<ul>\n<li>c</li>\n</ul></li>\n</ul>")
      expect(md("3. x\n4. y")).to eq(%(<ol start="3">\n<li>x</li>\n<li>y</li>\n</ol>))
    end

    it 'renders fenced code highlighted in its language, and indented code' do
      expect(md("```yaml\na: 1\n```"))
        .to eq(%(<pre class="code" data-lang="yaml"><code><span class="hl-key">a</span>: <span class="hl-num">1</span></code></pre>))
      expect(md("~~~\n<b>\n~~~")).to eq('<pre class="code"><code>&lt;b&gt;</code></pre>')
      expect(md("para\n\n    indented <x>")).to include('<pre class="code"><code>indented &lt;x&gt;</code></pre>')
    end

    it 'falls back to the default language for unlabelled code' do
      expect(md("```\ninclude foo\n```", default_lang: 'puppet')).to include('data-lang="puppet"', 'hl-kw')
    end

    it 'renders tables with alignment' do
      html = md("| a | b |\n|:--|--:|\n| `x` | 2 |")
      expect(html).to include('<th style="text-align: left">a</th>', '<td style="text-align: right">2</td>', '<code>x</code>')
    end
  end

  describe 'inline' do
    it 'renders emphasis, strong, strikethrough, code, and breaks' do
      expect(inline('*a* **b** _c_ __d__ ~~e~~ `f`'))
        .to eq('<em>a</em> <strong>b</strong> <em>c</em> <strong>d</strong> <del>e</del> <code>f</code>')
      expect(inline("a  \nb")).to eq("a<br>\nb")
    end

    it 'leaves underscores inside identifiers alone' do
      expect(inline('use foo_bar_baz and $a_b')).to eq('use foo_bar_baz and $a_b')
    end

    it 'does not apply markdown inside code' do
      expect(inline('`*not em* <b>`')).to eq('<code>*not em* &lt;b&gt;</code>')
    end

    it 'links code that names a known object, through the linker' do
      md = described_class.new(linker: ->(t) { t == 'apache::vhost' ? 'x.html' : nil })
      expect(md.inline('`apache::vhost` and `other`'))
        .to eq('<a class="xref" href="x.html"><code>apache::vhost</code></a> and <code>other</code>')
    end

    it 'turns images into links so nothing is fetched' do
      expect(inline('![logo](https://example.com/l.png)'))
        .to eq('<a href="https://example.com/l.png" rel="noopener noreferrer">logo (image)</a>')
    end

    it 'links autolinks and relative links' do
      expect(inline('<https://e.com>')).to eq('<a href="https://e.com" rel="noopener noreferrer">https://e.com</a>')
      expect(inline('[ref](REFERENCE.md#x)')).to eq('<a href="REFERENCE.md#x">ref</a>')
    end
  end

  describe 'untrusted input' do
    [
      ['<script>alert(1)</script>after', 'after'],
      ['<SCRIPT src=//e.com/x.js></SCRIPT>after', 'after'],
      ['<img src=x onerror=alert(1)>after', 'after'],
      ['<svg onload=alert(1)>after', 'after'],
      ['<iframe src="https://e.com"></iframe>after', 'after'],
      ['<a href="javascript:alert(1)">x</a>', 'x'],
      ['<b onmouseover="alert(1)">bold</b>', 'bold'],
      ['<style>body{display:none}</style>after', 'after'],
      ['<!-- <script>alert(1)</script> -->after', 'after'],
      ['<scr<script>ipt>alert(1)</script>', '']
    ].each do |input, text|
      it "reduces #{input.inspect} to text" do
        html = inline(input)
        expect(html).not_to match(%r{<(?!/?(b|i|em|strong|code)>)})
        expect(html).not_to match(/on\w+=|javascript:/i)
        expect(html).to include(text)
      end
    end

    [
      '[x](javascript:alert(1))', '[x](JaVaScRiPt:alert(1))', '[x](vbscript:msgbox)', '[x](data:text/html;base64,PHNjcmlwdD4=)',
      '[x](&#106;avascript:alert(1))', '![x](javascript:alert(1))', '<javascript:alert(1)>'
    ].each do |input|
      it "never makes a live link from #{input}" do
        expect(inline(input)).not_to match(/href="(?:javascript|vbscript|data):/i)
      end
    end

    it 'keeps a handful of bare inline tags and balances them' do
      expect(inline('a <b>bold</b> <kbd>K</kbd> <br/>')).to eq('a <b>bold</b> <kbd>K</kbd> <br>')
      expect(inline('<b>unclosed')).to eq('<b>unclosed</b>')
      expect(inline('stray </em> close')).to eq('stray  close')
      expect(inline('<b><i>x</b></i>')).to eq('<b><i>x</i></b>')
    end

    it 'shows angle brackets that are not HTML as text' do
      expect(inline('Array<String> and a < b > c')).to eq('Array&lt;String&gt; and a &lt; b &gt; c')
    end

    it 'escapes quotes so nothing breaks out of a link' do
      expect(inline('[x](https://e.com/"onmouseover="alert(1))')).not_to include('" onmouseover')
    end

    it 'cannot break out of a code block' do
      expect(described_class.render("```\n</code></pre><script>alert(1)</script>\n```")).not_to include('<script>')
    end

    it 'cannot break out of a heading id through the prefix a caller gives it' do
      html = md('# Usage', heading_prefix: 'p-a"><img src=x onerror=alert(1)>-')
      expect(html).not_to include('<img')
      expect(html).to start_with('<h2 id="p-a---img-src-x-onerror-alert-1---usage">')
      expect(html).to include('href="#p-a---img-src-x-onerror-alert-1---usage"')
    end

    it 'stops nesting block quotes past a depth no real document reaches, and keeps the rest as text' do
      html = md("#{'>' * 5000} deep")
      expect(html.scan('<blockquote>').size).to eq(described_class::MAX_DEPTH)
      expect(html).to include('&gt; deep')
    end

    it 'stops nesting lists the same way' do
      html = md("#{'- ' * 5000}deep")
      expect(html.scan('<ul>').size).to eq(described_class::MAX_DEPTH)
      expect(html).to include('- deep')
    end
  end
end
