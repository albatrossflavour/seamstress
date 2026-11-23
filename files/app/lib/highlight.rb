# frozen_string_literal: true

require 'erb'
require 'strscan'

module Seamstress
  # A small syntax highlighter for the code a module's documentation holds:
  # Puppet, Ruby, YAML, JSON, and shell. It runs at build time and emits
  # escaped HTML with <span class="hl-*"> around tokens, so pages need no
  # script and load nothing from anywhere else.
  module Highlight
    PUPPET_KEYWORDS = %w[
      and application attr case class consumes contain default define else elsif false function if import in
      inherits include node or plan private produces require site type undef unless true
    ].freeze
    RUBY_KEYWORDS = %w[
      alias and begin break case class def defined? do else elsif end ensure false for if in module next nil
      not or redo rescue retry return self super then true undef unless until when while yield
    ].freeze
    SHELL_KEYWORDS = %w[if then else elif fi for while until do done case esac in function select return export local].freeze

    VAR = /\$(?:::)?[a-z_]\w*(?:::\w+)*|\$\{[^}\n]*\}/
    DQ = /"(?:[^"\\]|\\.)*"/m
    SQ = /'(?:[^'\\]|\\.)*'/m
    NUM = /\b(?:0x\h+|\d+(?:\.\d+)?)\b/

    RULES = {
      'puppet' => [
        [%r{#[^\n]*|/\*.*?\*/}m, 'com'], [DQ, :interp], [SQ, 'str'], [VAR, 'var'],
        [/\b[a-z_]\w*(?=\s*[=+]>)/, 'key'], [/\b[A-Z]\w*(?:::[A-Z]\w*)*/, 'typ'],
        [/\b[a-z_]\w*(?:::[a-z_]\w*)*\b/, :word], [NUM, 'num']
      ],
      'ruby' => [
        [/#[^\n]*/, 'com'], [DQ, :interp], [SQ, 'str'], [/:[a-z_]\w*[?!]?|:'[^'\n]*'/, 'sym'],
        [/@@?[a-z_]\w*|\$\w+/, 'var'], [/\b[A-Z]\w*/, 'typ'], [/\b[a-z_]\w*[?!]?/, :word], [NUM, 'num']
      ],
      'yaml' => [
        [/(?<![^\s])#[^\n]*/, 'com'], [/^---$|^\.\.\.$/, 'kw'], [DQ, 'str'], [SQ, 'str'],
        [%r{[\w.:/-]+(?=[ \t]*:(?:[ \t]|$))}, 'key'], [/[&*][\w-]+/, 'var'],
        [/\b(?:true|false|null|yes|no|on|off)\b/i, 'kw'], [NUM, 'num']
      ],
      'json' => [
        [/"(?:[^"\\]|\\.)*"(?=\s*:)/, 'key'], [DQ, 'str'], [/\b(?:true|false|null)\b/, 'kw'], [/-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?/, 'num']
      ],
      'shell' => [
        [/(?<![^\s])#[^\n]*/, 'com'], [DQ, :interp], [SQ, 'str'], [/\$(?:\{[^}\n]*\}|\w+|[@*#?$!0-9])/, 'var'],
        [/(?<![\w-])--?[a-zA-Z][\w-]*/, 'opt'], [/\b[a-z_][\w-]*\b/, :word], [NUM, 'num']
      ]
    }.freeze

    KEYWORDS = { 'puppet' => PUPPET_KEYWORDS, 'ruby' => RUBY_KEYWORDS, 'shell' => SHELL_KEYWORDS }.freeze

    ALIASES = {
      'pp' => 'puppet', 'puppet' => 'puppet', 'epp' => 'puppet',
      'rb' => 'ruby', 'ruby' => 'ruby',
      'yaml' => 'yaml', 'yml' => 'yaml', 'hiera' => 'yaml', 'eyaml' => 'yaml',
      'json' => 'json', 'jsonc' => 'json',
      'sh' => 'shell', 'shell' => 'shell', 'bash' => 'shell', 'console' => 'shell', 'zsh' => 'shell', 'shell-session' => 'shell'
    }.freeze

    def self.language(name)
      ALIASES[name.to_s.downcase.strip]
    end

    def self.esc(text) = ERB::Util.html_escape(text)

    # Escaped, highlighted HTML for code in lang. Unknown languages come
    # back escaped and otherwise untouched.
    # Past this a block is shown plain. No real example is this long, and the
    # scanner's cost grows faster than the text does.
    MAX_BYTES = 20_000

    def self.html(code, lang)
      lang = language(lang)
      return esc(code) unless lang && code.to_s.bytesize <= MAX_BYTES

      rules = RULES.fetch(lang)
      keywords = KEYWORDS.fetch(lang, [])
      ss = StringScanner.new(code.to_s)
      out = +''
      out << (token(ss, rules, keywords, lang) || esc(ss.scan(/\s+|\w+|./m))) until ss.eos?
      out
    end

    def self.token(scanner, rules, keywords, lang)
      rules.each do |re, cls|
        text = scanner.scan(re) or next
        return span(cls == :word ? word_class(text, keywords, lang, scanner) : cls, text, lang)
      end
      nil
    end

    # A bare word is a keyword, a function call, or nothing in particular.
    def self.word_class(text, keywords, lang, scanner)
      return 'kw' if keywords.include?(text)
      return 'fn' if lang == 'puppet' && scanner.check(/\s*\(/)
      return 'fn' if lang == 'shell' && (scanner.pre_match.empty? || scanner.pre_match.match?(/(?:^|[|;&]\s*|\n\s*)\z/))

      nil
    end

    def self.span(cls, text, lang)
      return esc(text) if cls.nil?
      return interpolated(text, lang) if cls == :interp

      %(<span class="hl-#{cls}">#{esc(text)}</span>)
    end

    # A double-quoted string with its interpolated variables picked out.
    def self.interpolated(text, lang)
      re = lang == 'ruby' ? /#\{[^}\n]*\}/ : /\$\{[^}\n]*\}|\$(?:::)?[a-z_]\w*(?:::\w+)*/
      body = text.split(/(#{re})/).each_slice(2).map do |plain, var|
        "#{esc(plain)}#{%(<span class="hl-var">#{esc(var)}</span>) if var}"
      end.join
      %(<span class="hl-str">#{body}</span>)
    end
  end
end
