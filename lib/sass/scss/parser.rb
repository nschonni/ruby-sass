require 'strscan'
require 'set'

module Sass
  module SCSS
    # The parser for SCSS.
    # It parses a string of code into a tree of {Sass::Tree::Node}s.
    #
    # @todo Add a CSS-only parser that doesn't parse the SassScript extensions,
    #   so css2sass will work properly.
    # @todo Make multiline SassScript work,
    #   including reporting errors on the proper line.
    class Parser
      # @param str [String] The source document to parse
      def initialize(str)
        @scanner = StringScanner.new(str)
        @line = 1
        @strs = []
      end

      # Parses an SCSS document.
      #
      # @return [Sass::Tree::RootNode] The root node of the document tree
      # @raise [Sass::SyntaxError] if there's a syntax error in the document
      def parse
        root = stylesheet
        expected("selector or at-rule") unless @scanner.eos?
        root
      end

      private

      include Sass::SCSS::RX

      def stylesheet
        node = node(Sass::Tree::RootNode.new(@scanner.string))
        block_contents(node) {s(node)}
      end

      def s(node)
        while tok(S) || tok(CDC) || tok(CDO) || tok(SINGLE_LINE_COMMENT) || (c = tok(COMMENT))
          next unless c
          process_comment c, node
          c = nil
        end
        true
      end

      def ss
        nil while tok(S) || tok(SINGLE_LINE_COMMENT) || tok(COMMENT)
        true
      end

      def ss_comments(node)
        while tok(S) || tok(SINGLE_LINE_COMMENT) || (c = tok(COMMENT))
          next unless c
          process_comment c, node
          c = nil
        end

        true
      end

      def process_comment(text, node)
        pre_str = @scanner.string[/(?:\A|\n)(.*)\/\*/, 1].gsub(/[^\s]/, ' ')
        node << Sass::Tree::CommentNode.new(pre_str + text, false)
      end

      DIRECTIVES = Set[:mixin, :include, :debug, :for, :while, :if, :import]

      def directive
        return unless tok(/@/)
        name = tok!(IDENT)
        ss

        sym = name.gsub('-', '_').to_sym
        return send(sym) if DIRECTIVES.include?(sym)

        val = str do
          # Most at-rules take expressions (e.g. @media, @import),
          # but some (e.g. @page) take selector-like arguments
          expr || selector
        end
        node = node(Sass::Tree::DirectiveNode.new("@#{name} #{val}".strip))

        if tok(/\{/)
          block_contents(node)
          tok!(/\}/)
        end

        node
      end

      def mixin
        name = tok! IDENT
        args = sass_script(:parse_mixin_definition_arglist)
        ss
        block(node(Sass::Tree::MixinDefNode.new(name, args)))
      end

      def include
        name = tok! IDENT
        args = sass_script(:parse_mixin_include_arglist)
        ss
        node(Sass::Tree::MixinNode.new(name, args))
      end

      def debug
        node(Sass::Tree::DebugNode.new(sass_script(:parse)))
      end

      def for
        tok!(/!/)
        var = tok! IDENT
        ss

        tok!(/from/)
        from = sass_script(:parse_until, Set["to", "through"])
        ss

        @expected = '"to" or "through"'
        exclusive = (tok(/to/) || tok!(/through/)) == 'to'
        to = sass_script(:parse)
        ss

        block(node(Sass::Tree::ForNode.new(var, from, to, exclusive)))
      end

      def while
        expr = sass_script(:parse)
        ss
        block(node(Sass::Tree::WhileNode.new(expr)))
      end

      def if
        expr = sass_script(:parse)
        ss
        block(node(Sass::Tree::IfNode.new(expr)))
      end

      def import
        @expected = "string or url()"
        arg = tok(STRING) || tok!(URI)
        path = @scanner[1]
        ss

        media = str do
          if tok IDENT
            ss
            while tok(/,/)
              ss; tok(IDENT); ss
            end
          end
        end

        unless media.strip.empty?
          return node(Sass::Tree::DirectiveNode.new("@import #{path} #{media}".strip))
        end

        node(Sass::Tree::ImportNode.new(path.strip))
      end

      def variable
        return unless tok(/!/)
        name = tok!(IDENT)
        ss

        if tok(/\|/)
          tok!(/\|/)
          guarded = true
        end

        tok!(/=/)
        ss
        expr = sass_script(:parse)

        node(Sass::Tree::VariableNode.new(name, expr, guarded))
      end

      def operator
        # Many of these operators (all except / and ,)
        # are disallowed by the CSS spec,
        # but they're included here for compatibility
        # with some proprietary MS properties
        str {ss if tok(/[\/,:.=]/)}
      end

      def unary_operator
        tok(/[+-]/)
      end

      def property
        return unless e = (tok(IDENT) || interpolation)
        res = [e, str{ss}]

        while e = (interpolation || tok(IDENT))
          res << e
        end

        ss
        res
      end

      def ruleset
        rules = []
        return unless v = selector
        rules.concat v

        while tok(/,/)
          rules << ',' << str {ss}
          rules.concat expr!(:selector)
        end

        block(node(Sass::Tree::RuleNode.new(rules.flatten.compact)))
      end

      def block(node)
        tok!(/\{/)
        block_contents(node)
        tok!(/\}/)
        node
      end

      # A block may contain declarations and/or rulesets
      def block_contents(node)
        block_given? ? yield : ss_comments(node)
        node << (child = block_child)
        while tok(/;/) || (child && !child.children.empty?)
          block_given? ? yield : ss_comments(node)
          node << (child = block_child)
        end
        node
      end

      def block_child
        variable || directive || declaration_or_ruleset
      end

      # This is a nasty hack, and the only place in the parser
      # that requires backtracking.
      # The reason is that we can't figure out if certain strings
      # are declarations or rulesets with fixed finite lookahead.
      # For example, "foo:bar baz baz baz..." could be either a property
      # or a selector.
      #
      # To handle this, we simply check if it works as a property
      # (which is the most common case)
      # and, if it doesn't, try it as a ruleset.
      #
      # We could eke some more efficiency out of this
      # by handling some easy cases (first token isn't an identifier,
      # no colon after the identifier, whitespace after the colon),
      # but I'm not sure the gains would be worth the added complexity.
      def declaration_or_ruleset
        pos = @scanner.pos
        line = @line
        old_use_property_exception, @use_property_exception =
          @use_property_exception, false
        begin
          decl = declaration
          # We want an exception if it's not there,
          # but we don't want to consume if it is
          tok!(/[;}]/) unless tok?(/[;}]/)
          return decl
        rescue Sass::SyntaxError => decl_err
        end

        @line = line
        @scanner.pos = pos

        begin
          return ruleset
        rescue Sass::SyntaxError => ruleset_err
          raise @use_property_exception ? decl_err : ruleset_err
        end
      ensure
        @use_property_exception = old_use_property_exception
      end

      def selector
        # The combinator here allows the "> E" hack
        return unless (comb = combinator) || (seq = simple_selector_sequence)
        res = [comb] + (seq || [])

        while v = combinator
          res << v
          res.concat(simple_selector_sequence || [])
        end
        res
      end

      def combinator
        tok(PLUS) || tok(GREATER) || tok(TILDE) || tok(S)
      end

      def simple_selector_sequence
        # This allows for stuff like http://www.w3.org/TR/css3-animations/#keyframes-
        return expr unless e = element_name || tok(HASH) || class_expr ||
          attrib || negation || pseudo || tok(/&/) || interpolation
        res = [e]

        # The tok(/\*/) allows the "E*" hack
        while v = element_name || tok(HASH) || class_expr ||
            attrib || negation || pseudo || tok(/\*/) || interpolation
          res << v
        end
        res
      end

      def class_expr
        return unless tok(/\./)
        '.' + tok!(IDENT)
      end

      def element_name
        return unless name = tok(IDENT) || tok(/\*/) || tok?(/\|/)
        if tok(/\|/)
          @expected = "element name or *"
          name << "|" << (tok(IDENT) || tok!(/\*/))
        end
        name
      end

      def attrib
        return unless tok(/\[/)
        res = ['[', str{ss}, str{attrib_name!}, str{ss}]

        if m = tok(/=/) ||
            tok(INCLUDES) ||
            tok(DASHMATCH) ||
            tok(PREFIXMATCH) ||
            tok(SUFFIXMATCH) ||
            tok(SUBSTRINGMATCH)
          @expected = "identifier or string"
          res << m << str{ss} << (tok(IDENT) || expr!(:interp_string)) << str{ss}
        end
        res << tok!(/\]/)
      end

      def attrib_name!
        if tok(IDENT)
          # E, E|E, or E|
          # The last is allowed so that E|="foo" will work
          tok(IDENT) if tok(/\|/)
        elsif tok(/\*/)
          # *|E
          tok!(/\|/)
          tok! IDENT
        else
          # |E or E
          tok(/\|/)
          tok! IDENT
        end
      end

      def pseudo
        return unless s = tok(/::?/)

        @expected = "pseudoclass or pseudoelement"
        [s, functional_pseudo || tok!(IDENT)]
      end

      def functional_pseudo
        return unless fn = tok(FUNCTION)
        [fn, str{ss}, expr!(:pseudo_expr), tok!(/\)/)]
      end

      def pseudo_expr
        return unless e = tok(PLUS) || tok(/-/) || tok(NUMBER) ||
          interp_string || tok(IDENT) || interpolation
        res = [e, str{ss}]
        while e = tok(PLUS) || tok(/-/) || tok(NUMBER) ||
            interp_string || tok(IDENT) || interpolation
          res << e << str{ss}
        end
        res
      end

      def negation
        return unless tok(NOT)
        res = [":not(", str{ss}]
        @expected = "selector"
        res << (element_name || tok(HASH) || class_expr || attrib || expr!(:pseudo))
        res << tok!(/\)/)
      end

      def declaration
        # The tok(/\*/) allows the "*prop: val" hack
        if tok(/\*/)
          @use_property_exception = true
          name = ['*'] + expr!(:property)
        else
          return unless name = property
        end

        value =
          if tok(/=/)
            require_block = false
            expression = true
            space = true
            @use_property_exception = true
            [sass_script(:parse)]
          else
            @expected = '":" or "="'
            tok!(/:/)
            space = !str {ss}.empty?
            @use_property_exception ||= space || !tok?(IDENT)

            expression = expr
            expression << tok(IMPORTANT) if expression
            require_block = !expression
            expression || [""]
          end
        ss
        require_block ||= tok?(/\{/)

        node = node(Sass::Tree::PropNode.new(name.flatten.compact, value.flatten.compact, :new))

        if require_block && expression && !space
          @use_property_exception = true
          raise Sass::SyntaxError.new(<<MESSAGE, :line => @line)
Invalid CSS: a space is required between a property and its definition
when it has other properties nested beneath it.
MESSAGE
        end

        return node unless require_block

        @use_property_exception = true
        @expected = 'expression (e.g. 1px, bold) or "{"'
        block(node)
      end

      def expr
        return unless t = term
        res = [t, str{ss}]

        while (o = operator) && (t = term)
          res << o << t << str{ss}
        end

        res
      end

      def term
        unless e = tok(NUMBER) ||
            tok(URI) ||
            function ||
            interp_string ||
            tok(UNICODERANGE) ||
            tok(IDENT) ||
            # TODO: Constrain this to be a hexcolor
            tok(HASH) ||
            interpolation

          return unless op = unary_operator
          @expected = "number or function"
          [op, tok(NUMBER) || expr!(:function)]
        end
        e
      end

      def function
        return unless name = tok(FUNCTION)
        [name, str{ss}, expr, tok!(/\)/)]
      end

      def interpolation
        return unless tok(/#\{/)
        sass_script(:parse_interpolated)
      end

      def interp_string
        _interp_string(:double) || _interp_string(:single)
      end

      def _interp_string(type)
        return unless start = tok(Sass::Script::Lexer::STRING_REGULAR_EXPRESSIONS[[type, false]])
        res = [start]

        mid_re = Sass::Script::Lexer::STRING_REGULAR_EXPRESSIONS[[type, true]]
        # @scanner[2].empty? means we've started an interpolated section
        res << expr!(:interpolation) << tok(mid_re) while @scanner[2].empty?
        res
      end

      def str
        @strs.push ""
        yield
        @strs.last
      ensure
        @strs.pop
      end

      def node(node)
        node.line = @line
        node
      end

      def sass_script(*args)
        ScriptParser.new(@scanner, @line,
          @scanner.pos - (@scanner.string.rindex("\n") || 0)).send(*args)
      rescue Sass::SyntaxError => e
        e.modify_backtrace :line => @line
        raise e
      end

      EXPR_NAMES = {
        :medium => "medium (e.g. print, screen)",
        :pseudo_expr => "expression (e.g. fr, 2n+1)",
        :expr => "expression (e.g. 1px, bold)",
      }

      TOK_NAMES = Haml::Util.to_hash(
        Sass::SCSS::RX.constants.map {|c| [Sass::SCSS::RX.const_get(c), c.downcase]}).
        merge(IDENT => "identifier", /[;}]/ => '";"')

      def tok?(rx)
        @scanner.match?(rx)
      end

      def expr!(name)
        (e = send(name)) && (return e)
        expected(EXPR_NAMES[name] || name.to_s)
      end

      def tok!(rx)
        (t = tok(rx)) && (return t)
        name = TOK_NAMES[rx]

        unless name
          # Display basic regexps as plain old strings
          string = rx.source.gsub(/\\(.)/, '\1')
          name = rx.source == Regexp.escape(string) ? string.inspect : rx.inspect
        end

        expected(name)
      end

      def expected(name)
        pos = @scanner.pos

        after = @scanner.string[0...pos]
        # Get rid of whitespace between pos and the last token,
        # but only if there's a newline in there
        after.gsub!(/\s*\n\s*$/, '')
        # Also get rid of stuff before the last newline
        after.gsub!(/.*\n/, '')
        after = "..." + after[-15..-1] if after.size > 18

        expected = @expected || name

        was = @scanner.rest.dup
        # Get rid of whitespace between pos and the next token,
        # but only if there's a newline in there
        was.gsub!(/^\s*\n\s*/, '')
        # Also get rid of stuff after the next newline
        was.gsub!(/\n.*/, '')
        was = was[0...15] + "..." if was.size > 18

        raise Sass::SyntaxError.new(
          "Invalid CSS after \"#{after}\": expected #{expected}, was \"#{was}\"",
          :line => @line)
      end

      def tok(rx)
        res = @scanner.scan(rx)
        if res
          @line += res.count("\n")
          @expected = nil
          if !@strs.empty? && rx != COMMENT && rx != SINGLE_LINE_COMMENT
            @strs.each {|s| s << res}
          end
        end

        res
      end
    end
  end
end
