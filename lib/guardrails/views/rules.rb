# frozen_string_literal: true

require "set"
require_relative "element"

module Guardrails
  module Views
    # The rules, each a module answering `name`, `severity`, `framing`,
    # `suggestion`, and `hits(element, context)`: the Locations (with the
    # matched text) where the rule fires on one element. `context` carries
    # what a rule needs from the rest of the file. Severities and the
    # accessibility rules' quiet conditions match Audit and A11yAudit, plus
    # three the parser can justify: a spread of unseen attributes, an input
    # nested in a label, and a computed id all pass.
    module Rules
      Hit = Data.define(:location, :match)

      # What the accessibility rules need from the rest of the file: every
      # static `for` on a label, and the location of every input rendered
      # inside a label.
      Context = Data.define(:label_ids, :nested_inputs) do
        def self.for(elements)
          labels = elements.select { |element| element.tag == "label" }
          new(
            label_ids: labels.filter_map { |label| label["for"] }.reject(&:dynamic?).to_set(&:static_value),
            nested_inputs: labels.flat_map { |label| label.each_element.select { |inner| inner.tag == "input" } }
              .to_set(&:location)
          )
        end

        def labelled?(input)
          return true if nested_inputs.include?(input.location)

          id = input["id"]
          !id.nil? && (id.dynamic? || label_ids.include?(id.static_value))
        end
      end

      def self.all
        [TailwindArbitrary, RawColor, InlineStyle, ImageAlt, ButtonName, LinkName, InputLabel]
      end

      # Every match of +pattern+ in one static part, located at its column.
      def self.scan(part, pattern)
        part.text.to_enum(:scan, pattern).map do
          match = Regexp.last_match
          Hit.new(location: part.location.shifted(match.begin(0)), match: match[0])
        end
      end

      # One hit on the element itself.
      def self.hit(element)
        [Hit.new(location: element.location, match: element.tag)]
      end

      # A class token carrying an arbitrary value (`w-[13px]`) or property
      # (`[anchor-name:--x]`), variants included.
      module TailwindArbitrary
        TOKEN = /\S*\[[^\]\s]+\]\S*/

        extend self

        def name = "tailwind_arbitrary"
        def severity = :error
        def framing = "Arbitrary Tailwind values (bg-[#fa3] etc.) bypass your theme. Add the value to the theme and use the named utility."
        def suggestion = "use a theme utility, or add `# guardrails-ok: tailwind_arbitrary <reason>` above the line"

        def hits(element, _context)
          attribute = element["class"]
          return [] unless attribute

          attribute.static_parts.flat_map { |part| Rules.scan(part, TOKEN) }
        end
      end

      # A hex or rgb() literal in a colour-bearing attribute, the same set
      # Audit reads.
      module RawColor
        ATTRIBUTES = %w[style fill stroke color bgcolor background flood-color lighting-color stop-color].freeze
        DATA_COLOR = /\Adata-[\w-]*colou?r[\w-]*\z/
        LITERAL = /#(?:\h{3,4}|\h{6}|\h{8})\b|rgba?\([^)]*\)/

        extend self

        def name = "raw_color"
        def severity = :error
        def framing = "Hex/rgb literals in color attributes bypass your design tokens. Reference a token instead."
        def suggestion = "use a colour token, or add `# guardrails-ok: raw_color <reason>` above the line"

        def hits(element, _context)
          element.attributes.select { |attribute| colour_bearing?(attribute.name) }
            .flat_map { |attribute| attribute.static_parts.flat_map { |part| Rules.scan(part, LITERAL) } }
        end

        def colour_bearing?(name)
          ATTRIBUTES.include?(name) || name.match?(DATA_COLOR)
        end
      end

      module InlineStyle
        extend self

        def name = "inline_style"
        def severity = :warning
        def framing = "Inline style attributes bypass your design tokens. Extract them to a class that references defined tokens."
        def suggestion = "extract to a class, or add `# guardrails-ok: inline_style <reason>` above the line"

        def hits(element, _context)
          attribute = element["style"]
          attribute ? [Hit.new(location: attribute.location, match: "style")] : []
        end
      end

      # The quiet conditions the accessible-name rules share.
      module Accessible
        def named?(element)
          element.splat || element["aria-label"] || element["aria-labelledby"] ||
            element.dynamic_content? || !element.visible_text.empty?
        end
      end

      module ImageAlt
        extend self

        def name = "image_alt"
        def severity = :error
        def framing = "Images need accessible alt text. Use alt=\"\" for purely decorative images."
        def suggestion = "add an alt attribute (or alt=\"\" if decorative)"

        def hits(element, _context)
          element.tag == "img" && !element.splat && element["alt"].nil? ? Rules.hit(element) : []
        end
      end

      module ButtonName
        extend self
        extend Accessible

        def name = "button_name"
        def severity = :error
        def framing = "Buttons need an accessible name — text content, aria-label, or aria-labelledby."
        def suggestion = "add text, aria-label, or aria-labelledby"

        def hits(element, _context)
          element.tag == "button" && !named?(element) ? Rules.hit(element) : []
        end
      end

      module LinkName
        extend self
        extend Accessible

        def name = "link_name"
        def severity = :error
        def framing = "Links need an accessible name — text content, aria-label, or aria-labelledby."
        def suggestion = "add link text, aria-label, or aria-labelledby"

        def hits(element, _context)
          element.tag == "a" && element["href"] && element["title"].nil? && !named?(element) ? Rules.hit(element) : []
        end
      end

      module InputLabel
        NON_INTERACTIVE = %w[hidden submit button reset image].freeze

        extend self

        def name = "input_label"
        def severity = :error
        def framing = "Interactive inputs need a programmatic label — aria-label, aria-labelledby, a matching <label for=...>, or a wrapping label."
        def suggestion = "add aria-label, aria-labelledby, or a matching <label for=...>"

        def hits(element, context)
          return [] unless element.tag == "input" && !element.splat && interactive?(element)
          return [] if element["aria-label"] || element["aria-labelledby"] || context.labelled?(element)

          Rules.hit(element)
        end

        def interactive?(input)
          type = input["type"]
          type.nil? || type.dynamic? || !NON_INTERACTIVE.include?(type.static_value.downcase)
        end
      end
    end
  end
end
