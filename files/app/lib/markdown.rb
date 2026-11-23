# frozen_string_literal: true

require 'erb'
require_relative 'highlight'

module Seamstress
  # Markdown to HTML for READMEs and docstrings, which come from modules
  # nobody here wrote and so are treated as hostile. Raw HTML never reaches
  # the page: script and style blocks are dropped with their content, a
  # handful of attribute-free inline tags are kept, and every other tag is
  # removed. Links keep only http, https, mailto, and relative targets, and
  # images become links, so a page never fetches anything from elsewhere.
  #
  # It covers what module docs use: headings, paragraphs, lists, block
  # quotes, fenced and indented code, tables, rules, and the usual inline
  # marks. It is not a full CommonMark implementation.
  class Markdown
    ALLOWED_TAGS = %w[b i em strong code kbd sub sup br s del ins small mark].freeze
    SAFE_URL = %r{\A(?:https?://|mailto:|[^:]*\z|[^:]*[/?#])}i
    UNESCAPE = { '&amp;' => '&', '&lt;' => '<', '&gt;' => '>', '&quot;' => '"', '&#39;' => "'" }.freeze
    # Real HTML element names. Anything else in angle brackets, such as
    # Array<String>, is prose and is shown escaped rather than removed.
    HTML_TAGS = %w[
      a abbr address area article aside audio b base bdi bdo big blink blockquote body br button canvas caption center
      cite code col colgroup data datalist dd del details dfn dialog dir div dl dt em embed fieldset figcaption figure
      font footer form frame frameset h1 h2 h3 h4 h5 h6 head header hgroup hr html i iframe img input ins kbd label
      legend li link main map mark marquee math menu meta meter nav noscript object ol optgroup option output p param
      picture pre progress q rp rt ruby s samp script section select slot small source span strike strong style sub
      summary sup svg table tbody td template textarea tfoot th thead time title tr track tt u ul var video wbr
    ].freeze

    # How deep block quotes and lists may nest. Each level is a level of
    # recursion here, so a line of a few thousand > would overflow the stack;
    # past this depth what is left is shown as text.
    MAX_DEPTH = 16

    # linker: called with the text of an inline code span; returns a URL to
    # link it to, or nil. heading_prefix: prefix for heading ids, so a README
    # cannot clash with the page's own anchors. A caller may build the prefix
    # from a name a module supplied, so it is cut down to what an id can
    # safely hold before it goes anywhere near an attribute.
    def initialize(linker: nil, heading_prefix: 'md-', default_lang: nil, heading_offset: 1)
      @linker = linker
      @prefix = heading_prefix.to_s.gsub(/[^\w-]/, '-')
      @default_lang = default_lang
      @offset = heading_offset
      @ids = Hash.new(0)
      @depth = 0
    end

    def self.render(text, **) = new(**).render(text)

    # Block structure.
    FENCE = /\A {0,3}(`{3,}|~{3,})\s*([\w+-]*)/
    LIST = /\A( {0,3})([-*+]|\d{1,9}[.)])( +|\z)/
    HEADING = /\A {0,3}(\#{1,6})(?:\s+(.*?))?(?:\s+#+)?\s*\z/
    RULE = /\A {0,3}([-*_])(?:\s*\1){2,}\s*\z/
    TABLE_SEP = /\A\s*\|?\s*:?-+:?\s*(\|\s*:?-+:?\s*)*\|?\s*\z/

    DROPPED = %r{<(script|style|iframe|object|embed|template|noscript|textarea|title)\b.*?(?:</\1\s*>|\z)}im

    def render(text)
      text = text.to_s.gsub(/\r\n?/, "\n").gsub(/<!--.*?(?:-->|\z)/m, '').gsub(DROPPED, '')
      blocks(text.split("\n", -1))
    end

    # Inline markdown only, for one-line summaries.
    def inline(text)
      held = []
      hold = ->(html) { "\u0000#{(held << html).size - 1}\u0000" }
      s = text.to_s.gsub(/<!--.*?(?:-->|\z)/m, '').gsub(DROPPED, '')
      s = s.gsub(/(`+)(.+?)\1/m) { hold.call(code_span(Regexp.last_match(2))) }
      s = sanitise(s)
      s = s.gsub(/!\[([^\]]*)\]\(([^)\s]*)(?:\s+&quot;[^)]*&quot;)?\)/) do
        hold.call(link(Regexp.last_match(2), Regexp.last_match(1).empty? ? 'image' : Regexp.last_match(1), image: true))
      end
      s = s.gsub(/\[([^\]]+)\]\(([^)\s]*)(?:\s+&quot;[^)]*&quot;)?\)/) { hold.call(link(Regexp.last_match(2), Regexp.last_match(1))) }
      s = s.gsub(%r{&lt;((?:https?://|mailto:)[^\s&]+)&gt;}) { hold.call(link(Regexp.last_match(1), Regexp.last_match(1))) }
      s = emphasis(s)
      s = s.gsub(/ {2,}\n|\\\n/, "<br>\n")
      s.gsub(/\u0000(\d+)\u0000/) { held[Regexp.last_match(1).to_i] }
    end

    private

    # Removes raw HTML apart from a few bare inline tags, then escapes.
    def sanitise(text)
      stripped = text.gsub(%r{</?([a-zA-Z][\w-]*)(\s[^<>]*)?/?>}) do |tag|
        name = Regexp.last_match(1).downcase
        next tag unless HTML_TAGS.include?(name)

        ALLOWED_TAGS.include?(name) && Regexp.last_match(2).nil? ? tag.downcase : ''
      end
      balance(esc(stripped).gsub(%r{&lt;(/?)(#{ALLOWED_TAGS.join('|')})/?&gt;}) { "<#{Regexp.last_match(1)}#{Regexp.last_match(2)}>" })
    end

    # Keeps the allowed tags properly nested: a close with no matching open
    # is dropped and anything left open is closed, so a stray <b> cannot
    # bold the rest of the page.
    def balance(html)
      stack = []
      out = html.gsub(%r{<(/?)(\w+)>}) do |tag|
        close = !Regexp.last_match(1).empty?
        name = Regexp.last_match(2)
        if name == 'br' then tag
        elsif !close then (stack << name) && tag
        elsif stack.last == name then stack.pop && tag
        else ''
        end
      end
      out + stack.reverse.map { |n| "</#{n}>" }.join
    end

    def emphasis(text)
      text.gsub(/\*\*(?=\S)(.+?)(?<=\S)\*\*/, '<strong>\1</strong>')
          .gsub(/(?<![\w\\])__(?=\S)(.+?)(?<=\S)__(?!\w)/, '<strong>\1</strong>')
          .gsub(/(?<![\w*\\])\*(?=[^\s*])(.+?)(?<=[^\s*])\*(?![\w*])/, '<em>\1</em>')
          .gsub(/(?<![\w\\])_(?=[^\s_])(.+?)(?<=[^\s_])_(?!\w)/, '<em>\1</em>')
          .gsub(/~~(?=\S)(.+?)(?<=\S)~~/, '<del>\1</del>')
          .gsub(/\\([\\`*_{}\[\]()#+\-.!|>~])/, '\1')
    end

    def code_span(text)
      code = text.strip
      url = @linker&.call(code)
      inner = "<code>#{esc(code)}</code>"
      url ? %(<a class="xref" href="#{esc(url)}">#{inner}</a>) : inner
    end

    # url and label arrive already escaped.
    def link(url, label, image: false)
      raw = url.gsub(/&(?:amp|lt|gt|quot|#39);/, UNESCAPE)
      return label unless raw.match?(SAFE_URL)

      text = image ? "#{label} (image)" : label
      %(<a href="#{esc(raw)}"#{' rel="noopener noreferrer"' if raw.match?(%r{\Ahttps?://}i)}>#{text}</a>)
    end

    def esc(text) = ERB::Util.html_escape(text)

    # Block structure.

    def blocks(lines)
      return "<p>#{inline(lines.join("\n").strip)}</p>" if @depth >= MAX_DEPTH

      @depth += 1
      out = []
      i = 0
      i = block(lines, i, out) while i < lines.size
      out.join("\n")
    ensure
      @depth -= 1 if out
    end

    # Renders the block starting at lines[at] into out and returns the index
    # of the line after it.
    def block(lines, at, out)
      line = lines[at]
      return at + 1 if line.strip.empty?
      return fence(lines, at, line.match(FENCE), out) if line.match?(FENCE)

      if (m = line.match(HEADING)) then out << heading(m[1].size, m[2].to_s)
      elsif line.match?(RULE) then out << '<hr>'
      else return container(lines, at, out)
      end
      at + 1
    end

    def container(lines, at, out)
      line = lines[at]
      if line.match?(/\A {0,3}>/) then quote(lines, at, out)
      elsif line.match?(LIST) then list(lines, at, out)
      elsif line.match?(/\A(?: {4,}\S|\t)/) then indented(lines, at, out)
      elsif line.include?('|') && lines[at + 1].to_s.match?(TABLE_SEP) && lines[at + 1].include?('-') then table(lines, at, out)
      else paragraph(lines, at, out)
      end
    end

    def fence(lines, start, match, out)
      marker = match[1]
      indent = lines[start][/\A */].size
      lang = match[2].empty? ? @default_lang : match[2]
      body = []
      i = start + 1
      while i < lines.size && !lines[i].match?(/\A {0,3}#{Regexp.escape(marker[0])}{#{marker.size},}\s*\z/)
        body << lines[i].sub(/\A {0,#{indent}}/, '')
        i += 1
      end
      out << code_block(body.join("\n"), lang)
      i + 1
    end

    def indented(lines, start, out)
      body = []
      i = start
      while i < lines.size && (lines[i].match?(/\A(?: {4}|\t)/) || (lines[i].strip.empty? && lines[i + 1].to_s.match?(/\A(?: {4}|\t)/)))
        body << lines[i].sub(/\A(?: {4}|\t)/, '')
        i += 1
      end
      out << code_block(body.join("\n"), @default_lang)
      i
    end

    def code_block(code, lang)
      language = Highlight.language(lang)
      attr = language ? %( data-lang="#{language}") : ''
      %(<pre class="code"#{attr}><code>#{Highlight.html(code, lang)}</code></pre>)
    end

    def heading(level, text)
      slug = text.downcase.gsub(/<[^>]*>|`/, '').gsub(/[^a-z0-9]+/, '-').gsub(/\A-|-\z/, '')
      slug = 'section' if slug.empty?
      id = "#{@prefix}#{slug}"
      @ids[id] += 1
      id = "#{id}-#{@ids[id]}" if @ids[id] > 1
      level = [level + @offset, 6].min # the page's own h1 stays the only one
      %(<h#{level} id="#{id}">#{inline(text)}<a class="anchor" href="##{id}" aria-label="Link to this section">#</a></h#{level}>)
    end

    def quote(lines, start, out)
      body = []
      i = start
      while i < lines.size && !lines[i].strip.empty?
        line = lines[i]
        break if body.any? && !line.match?(/\A {0,3}>/) && block_start?(line)

        body << line.sub(/\A {0,3}> ?/, '')
        i += 1
      end
      out << "<blockquote>\n#{blocks(body)}\n</blockquote>"
      i
    end

    def block_start?(line)
      line.match?(FENCE) || line.match?(HEADING) || line.match?(LIST) || line.match?(RULE)
    end

    def list(lines, start, out)
      first = lines[start].match(LIST)
      ordered = first[2].match?(/\d/)
      items = []
      i = start
      while i < lines.size
        m = lines[i].match(LIST)
        break unless m && m[1].size <= first[1].size + 1 && m[2].match?(/\d/) == ordered

        item, i = list_item_lines(lines, i, m[0].size)
        items << item
      end
      tag = ordered ? 'ol' : 'ul'
      start_at = ordered && first[2].to_i != 1 ? %( start="#{first[2].to_i}") : ''
      out << "<#{tag}#{start_at}>\n#{items.map { |item| "<li>#{list_item(item)}</li>" }.join("\n")}\n</#{tag}>"
      i
    end

    # The lines of one list item, its marker removed and its continuation
    # lines dedented, and the index of the line after it.
    def list_item_lines(lines, start, width)
      item = [lines[start][width..].to_s]
      indent = /\A {#{[width, 2].min},}\S/
      i = start + 1
      while i < lines.size
        line = lines[i]
        if line.strip.empty?
          break unless lines[i + 1].to_s.match?(indent) && !lines[i + 1].match?(LIST)

          item << ''
        elsif line.match?(indent) then item << line.sub(/\A {0,#{width}}/, '')
        elsif !line.match?(LIST) && !block_start?(line) && !item.last.strip.empty? then item << line # lazy continuation
        else break
        end
        i += 1
      end
      [item, i]
    end

    # A tight item (one paragraph, maybe a nested list) renders without <p>.
    def list_item(item_lines)
      html = blocks(item_lines)
      html.sub(%r{\A<p>(.*?)</p>(?=\n<[uo]l|\z)}m, '\1')
    end

    def table(lines, start, out)
      head = cells(lines[start])
      aligns = cells(lines[start + 1]).map { |c| alignment(c) }
      i = start + 2
      rows = []
      while i < lines.size && lines[i].include?('|') && !lines[i].strip.empty?
        rows << cells(lines[i])
        i += 1
      end
      row = lambda do |tag, values|
        head.each_index.map { |n| "<#{tag}#{align(aligns[n])}>#{inline(values[n].to_s.gsub('\\|', '|'))}</#{tag}>" }.join
      end
      body = rows.map { |r| "<tr>#{row.call('td', r)}</tr>" }.join("\n")
      out << %(<div class="table-wrap"><table>\n<thead><tr>#{row.call('th', head)}</tr></thead>\n<tbody>\n#{body}\n</tbody>\n</table></div>)
      i
    end

    def cells(row) = row.strip.sub(/\A\|/, '').sub(/\|\z/, '').split(/(?<!\\)\|/).map(&:strip)

    def alignment(cell)
      if cell.start_with?(':') && cell.end_with?(':') then 'center'
      elsif cell.end_with?(':') then 'right'
      elsif cell.start_with?(':') then 'left'
      end
    end

    def align(value) = value ? %( style="text-align: #{value}") : ''

    def paragraph(lines, start, out)
      body = []
      i = start
      while i < lines.size && !lines[i].strip.empty?
        line = lines[i]
        break if body.any? && (block_start?(line) || line.match?(/\A {0,3}>/))

        if body.any? && line.match?(/\A {0,3}(=+|-+)\s*\z/)
          out << heading(line.include?('=') ? 1 : 2, body.join(' '))
          return i + 1
        end
        body << line
        i += 1
      end
      out << "<p>#{inline(body.map(&:lstrip).join("\n").rstrip).strip}</p>"
      i
    end
  end
end
