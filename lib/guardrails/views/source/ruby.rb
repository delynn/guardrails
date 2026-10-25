# frozen_string_literal: true

require "pathname"
require "prism"
require_relative "../element"

module Guardrails
  module Views
    module Source
      # Reads Phlex views, plus `tag.div(...)` and `content_tag(:div, ...)`
      # helper calls (ViewComponent `call` methods, helpers), into Elements
      # with a Prism walk over one Ruby file.
      #
      # An element call is a receiverless call named like an HTML element
      # with no positional arguments (`div(class: "x") { … }`). Keyword
      # arguments become attributes with Phlex's own naming (`aria_label:`
      # → aria-label, `data: { foo_bar: }` → data-foo-bar). A string
      # literal that is the block's value, and `plain "…"`, are Static
      # text; every other call in a body is Dynamic content. A constant
      # assigned a string or array literal in the same file, or an
      # argument-less method whose body is one such literal, resolves to
      # that literal, so `class: BASE` and `class: grid_classes` are
      # inspected where the literal is written.
      #
      # +label_wrappers+ names helpers that render their block inside a
      # label (`labeled("Amount") { input(...) }`); the walk models each as
      # a label element so the input counts as labelled.
      class Ruby
        EXTENSION = ".rb"

        # Every HTML element Phlex spells as a method (underscores become
        # dashes). SVG elements are left out: Phlex views call them on the
        # block parameter (`svg { |s| s.path }`), so a receiverless `title`
        # or `symbol` is never one.
        STANDARD_ELEMENTS = %w[
          a abbr address article aside audio b bdi bdo blockquote body button canvas caption cite code
          colgroup data datalist dd del details dfn dialog div dl dt em fencedframe fieldset figcaption
          figure footer form h1 h2 h3 h4 h5 h6 head header hgroup html i iframe ins kbd label legend li
          main map mark menu meter nav noscript object ol optgroup option output p picture pre progress q
          rp rt ruby s samp script search section select selectedcontent slot small span strong style sub
          summary sup svg table tbody td template textarea tfoot th thead time title tr u ul var video wbr
        ].freeze
        VOID_ELEMENTS = %w[area base br col embed hr img input link meta source track].freeze

        # Method name → tag.
        VOCABULARY = (STANDARD_ELEMENTS + VOID_ELEMENTS).to_h { |tag| [tag.tr("-", "_").to_sym, tag] }.freeze

        SILENT = %i[whitespace comment].freeze
        LITERALS = [Prism::StringNode, Prism::InterpolatedStringNode, Prism::ArrayNode].freeze

        # +path+ is relative to +root+ and is what every Location reports.
        # +content+ replaces the file on disk (a version at HEAD, say).
        def initialize(root:, path:, content: nil, label_wrappers: [])
          @path = Pathname(root).join(path)
          @relative = path.to_s
          @content = content
          @label_wrappers = label_wrappers.map(&:to_sym)
        end

        def elements
          @constants = {}
          program = Prism.parse(@content || File.read(@path, encoding: Encoding::UTF_8)).value
          collect_constants(program)
          collected(program).grep(Element)
        end

        private

        # Constants and argument-less methods whose value is one literal, so
        # `class: BASE` and `class: grid_classes` resolve. Only literals are
        # kept: a constant that aliases another stays Dynamic.
        def collect_constants(node)
          case node
          when Prism::ConstantWriteNode then remember(node.name, node.value)
          when Prism::DefNode then remember(node.name, single_statement(node.body)) if node.parameters.nil?
          end
          node.compact_child_nodes.each { |child| collect_constants(child) }
        end

        def remember(name, node)
          literal = unfreeze(node)
          @constants[name] = literal if LITERALS.any? { |type| literal.is_a?(type) }
        end

        def single_statement(body)
          statements = body.is_a?(Prism::StatementsNode) ? body.body : [body]
          statements.first if statements.length == 1
        end

        def unfreeze(node)
          frozen = node.is_a?(Prism::CallNode) && node.name == :freeze && node.receiver
          frozen ? node.receiver : node
        end

        # Walks +node+, appending Elements, Statics, and Dynamics to +into+.
        def collect(node, into)
          if node.is_a?(Prism::CallNode)
            collect_call(node, into)
          else
            node.compact_child_nodes.each { |child| collect(child, into) }
          end
        end

        def collect_call(node, into)
          if (tag = element_tag(node))
            into << build_element(node, tag)
          elsif @label_wrappers.include?(node.name) && node.receiver.nil? && node.block
            into << build_element(node, "label")
          elsif node.name == :plain && node.receiver.nil?
            into.concat(text_parts(node.arguments&.arguments&.first))
          elsif SILENT.include?(node.name) && node.receiver.nil?
            nil
          else
            into << Dynamic.new(code: node.name.to_s, location: location_of(node.location))
            node.compact_child_nodes.each { |child| collect(child, into) }
          end
        end

        def element_tag(node)
          args = node.arguments&.arguments || []
          if node.name == :content_tag && node.receiver.nil? && args.first.is_a?(Prism::SymbolNode)
            args.first.unescaped
          elsif node.receiver.nil? || tag_receiver?(node.receiver)
            return nil unless args.all? { |arg| arg.is_a?(Prism::KeywordHashNode) || arg.is_a?(Prism::BlockArgumentNode) }

            node.receiver ? node.name.to_s.tr("_", "-") : VOCABULARY[node.name]
          end
        end

        # `tag.div` and `helpers.tag.div`.
        def tag_receiver?(receiver)
          receiver.is_a?(Prism::CallNode) && receiver.name == :tag &&
            (receiver.receiver.nil? || receiver.receiver.is_a?(Prism::CallNode))
        end

        def build_element(node, tag)
          attributes = []
          splat = false
          (node.arguments&.arguments || []).grep(Prism::KeywordHashNode).each do |hash|
            hash.elements.each do |pair|
              pair.is_a?(Prism::AssocSplatNode) ? (splat = true) : attributes.concat(attributes_for(pair))
            end
          end
          Element.new(tag: tag, attributes: attributes, children: body_children(node.block),
                      location: location_of(node.location), splat: splat)
        end

        # Phlex renders the block's value as text only when nothing in the
        # block wrote to the buffer first, so the implicit text is taken
        # only when every earlier statement is something other than a
        # call. A last statement that is neither text nor something the
        # walk can read (a variable holding the label, say) is Dynamic
        # content.
        def body_children(block)
          return [] unless block.is_a?(Prism::BlockNode) && block.body.is_a?(Prism::StatementsNode)

          statements = block.body.body
          quiet = statements[0...-1].none? { |statement| statement.is_a?(Prism::CallNode) }
          *leading, last = statements
          text = implicit_text(last)
          value = text ? (quiet ? text : []) : collected_or_dynamic(last)
          leading.flat_map { |statement| collected(statement) } + value
        end

        # The block's value is rendered as text when it is a string
        # literal, including through the branches of a conditional. A
        # branch that is not text contributes whatever it renders, or a
        # Dynamic placeholder.
        def implicit_text(node)
          case node
          when Prism::StringNode, Prism::InterpolatedStringNode then text_parts(node)
          when Prism::IfNode, Prism::UnlessNode
            branches = [node.statements, node.is_a?(Prism::IfNode) ? node.subsequent : node.else_clause].compact
            return nil if branches.none? { |branch| implicit_text(branch) }

            branches.flat_map { |branch| implicit_text(branch) || collected_or_dynamic(branch) }
          when Prism::StatementsNode then implicit_text(node.body.last)
          when Prism::ElseNode then implicit_text(node.statements)
          end
        end

        def collected(node)
          [].tap { |into| collect(node, into) }
        end

        def collected_or_dynamic(node)
          parts = collected(node)
          parts.empty? ? [dynamic(node)] : parts
        end

        def text_parts(node)
          case node
          when nil then []
          when Prism::StringNode then [Static.new(text: node.unescaped, location: location_of(node.content_loc))]
          when Prism::InterpolatedStringNode then node.parts.flat_map { |part| text_parts(part) }
          when Prism::EmbeddedStatementsNode
            inner = node.statements&.body
            inner&.length == 1 ? text_parts(inner.first) : [dynamic(node)]
          when Prism::ConstantReadNode, Prism::CallNode
            resolvable?(node) ? text_parts(@constants[node.name]) : [dynamic(node)]
          when Prism::SymbolNode
            [Static.new(text: node.unescaped.tr("_", "-"), location: location_of(node.location))]
          when Prism::ArrayNode then node.elements.flat_map { |entry| text_parts(entry) }
          when Prism::IntegerNode, Prism::FloatNode
            [Static.new(text: node.slice, location: location_of(node.location))]
          else [dynamic(node)]
          end
        end

        def resolvable?(node)
          case node
          when Prism::ConstantReadNode then @constants.key?(node.name)
          when Prism::CallNode
            node.receiver.nil? && node.arguments.nil? && node.block.nil? && @constants.key?(node.name)
          else false
          end
        end

        def dynamic(node)
          Dynamic.new(code: node.slice, location: location_of(node.location))
        end

        # One keyword pair → one attribute, or several for a nested hash
        # (`data: { foo_bar: 1 }` → data-foo-bar). A `style:` hash is the
        # one Phlex renders as a single CSS string, so it stays one
        # attribute whose value the parser cannot read.
        def attributes_for(pair, prefix = nil)
          name = attribute_name(pair.key)
          return [] unless name

          name = "#{prefix}-#{name}" if prefix
          value = pair.value
          if value.is_a?(Prism::HashNode) && name != "style"
            value.elements.grep(Prism::AssocNode).flat_map { |nested| attributes_for(nested, name) }
          else
            [Attribute.new(name: name, parts: text_parts(value), location: location_of(pair.location))]
          end
        end

        def attribute_name(key)
          case key
          when Prism::SymbolNode then key.unescaped.tr("_", "-")
          when Prism::StringNode then key.unescaped
          end
        end

        # Columns are characters, as Herb's are, not bytes.
        def location_of(prism_location)
          Location.new(file: @relative, line: prism_location.start_line,
                       column: prism_location.start_character_column + 1)
        end
      end
    end
  end
end
