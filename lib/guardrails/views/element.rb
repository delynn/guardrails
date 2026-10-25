# frozen_string_literal: true

module Guardrails
  module Views
    # The parser-agnostic view model every rule reads. A source (Prism for
    # Ruby and Phlex, Herb for ERB) turns a file into Elements; rules never
    # see a parser node. Attribute values and element bodies are lists of
    # Static text the parser could read and Dynamic placeholders for
    # anything it could not, so a rule can prove a value is present
    # without guessing at code.
    Location = Data.define(:file, :line, :column) do
      def to_s
        [file, line, column].compact.join(":")
      end

      def shifted(by)
        with(column: column + by)
      end

      def to_report
        Report::Location.new(file: file, line: line, column: column)
      end
    end

    Static = Data.define(:text, :location)
    Dynamic = Data.define(:code, :location)

    Attribute = Data.define(:name, :parts, :location) do
      def static_parts
        parts.grep(Static)
      end

      def static_value
        static_parts.map(&:text).join
      end

      def dynamic?
        parts.any?(Dynamic)
      end
    end

    # `splat` is true when the source spreads attributes the parser cannot
    # see (`**attrs`, `<div <%= attrs %>>`), so rules that need an
    # attribute to be provably absent stay quiet. `children` holds
    # Elements, Statics (text), and Dynamics (content the parser could not
    # read, such as a rendered component).
    Element = Data.define(:tag, :attributes, :children, :location, :splat) do
      def [](name)
        attributes.find { |attribute| attribute.name == name }
      end

      def elements
        children.grep(Element)
      end

      def visible_text
        children.filter_map { |child| child.is_a?(Static) ? child.text : (child.visible_text if child.is_a?(Element)) }
          .join(" ").split.join(" ")
      end

      def dynamic_content?
        children.any? { |child| child.is_a?(Dynamic) || (child.is_a?(Element) && child.dynamic_content?) }
      end

      # Self, then every descendant element, depth first.
      def each_element(&block)
        return enum_for(:each_element) unless block

        yield self
        elements.each { |element| element.each_element(&block) }
      end
    end
  end
end
