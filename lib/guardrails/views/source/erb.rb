# frozen_string_literal: true

require "pathname"
require "herb"
require_relative "../element"

module Guardrails
  module Views
    module Source
      # Reads an ERB template into Elements with a Herb parse. Every HTML
      # element becomes an Element, as does an open tag Herb could not pair
      # with a close tag (a wrapper closed in another partial), whose body
      # is then unknown. Attribute values split into Static text and a
      # Dynamic part per `<%= %>`; `<%= %>` in a body is Dynamic content,
      # and so is a block helper's output (`<%= form_with do %>`), whose
      # body is walked like any other. Control flow (`<% if %>`), comments,
      # and `<% %>` statements render nothing and are walked through, in a
      # value or a body alike. ERB inside an open tag (`<div <%= attrs %>>`),
      # an attribute whose name is computed, and an open tag that differs
      # by branch (`<% if %><div class="a"><% else %><div class="b"><% end %>`)
      # set `splat`, and every branch's attributes are read.
      #
      # +content+ replaces the file on disk. With +line+ it is a template
      # embedded in another file (a ViewComponent `erb_template` heredoc):
      # every Location then reports +path+ with its lines offset to where
      # the template sits.
      class Erb
        EXTENSION = ".erb"

        def initialize(root:, path:, content: nil, line: 1)
          @path = Pathname(root).join(path)
          @relative = path.to_s
          @content = content
          @line_offset = line - 1
        end

        def elements
          document = Herb.parse(@content || File.read(@path, encoding: Encoding::UTF_8)).value
          collected(document.children).grep(Element)
        end

        private

        def collected(nodes)
          [].tap { |into| nodes.each { |node| collect(node, into) } }
        end

        def collect(node, into)
          case node
          when Herb::AST::HTMLElementNode then into << build_element(node.open_tag, collected(node.body))
          when Herb::AST::HTMLOpenTagNode then into << build_element(node, [unclosed(node)])
          when Herb::AST::HTMLTextNode then into.concat(static_parts(node.content, node.location))
          when Herb::AST::HTMLCommentNode then nil
          else
            into << dynamic(node) if output?(node)
            node.compact_child_nodes.each { |child| collect(child, into) }
          end
        end

        # `<%= %>` writes to the page; `<% %>` and `<%# %>` do not.
        def output?(node)
          node.respond_to?(:tag_opening) && node.tag_opening&.value.to_s.start_with?("<%=")
        end

        # +open_tag+ is a plain open tag or a conditional one holding an
        # open tag per branch.
        def build_element(open_tag, children)
          tags = open_tags(open_tag)
          tag_children = tags.flat_map(&:children)
          attributes = tag_children.grep(Herb::AST::HTMLAttributeNode).filter_map { |child| attribute_for(child) }
          Element.new(tag: open_tag.tag_name.value.downcase, attributes: attributes, children: children,
                      location: location_of(open_tag.location),
                      splat: tags.length > 1 || attributes.length != tag_children.length)
        end

        def open_tags(node)
          return [node] if node.is_a?(Herb::AST::HTMLOpenTagNode)

          node.compact_child_nodes.flat_map { |child| open_tags(child) }
        end

        # Nil when the name is computed (`<%= attr %>="x"`): the element
        # then carries an attribute the parser cannot name.
        def attribute_for(node)
          names = node.name.children
          return nil unless names.all?(Herb::AST::LiteralNode)

          parts = [].tap { |into| (node.value&.children || []).each { |part| collect_value(part, into) } }
          Attribute.new(name: names.map(&:content).join.downcase, parts: parts, location: location_of(node.location))
        end

        def collect_value(node, into)
          if node.is_a?(Herb::AST::LiteralNode)
            into.concat(static_parts(node.content, node.location))
          else
            into << dynamic(node) if output?(node)
            node.compact_child_nodes.each { |child| collect_value(child, into) }
          end
        end

        # One Static per line of +text+ so a rule's column arithmetic stays
        # on the line it matched. Each line keeps its newline and
        # continuation lines their indentation, so joined parts read as
        # written.
        def static_parts(text, herb_location)
          text.each_line.with_index.filter_map do |segment, index|
            next if segment.strip.empty?

            column = index.zero? ? herb_location.start.column : 0
            Static.new(text: segment, location: location(herb_location.start.line + index, column))
          end
        end

        def dynamic(node)
          Dynamic.new(code: node.content.value.strip, location: location_of(node.location))
        end

        def unclosed(open_tag)
          Dynamic.new(code: "unclosed #{open_tag.tag_name.value}", location: location_of(open_tag.location))
        end

        def location_of(herb_location)
          location(herb_location.start.line, herb_location.start.column)
        end

        def location(line, column)
          Location.new(file: @relative, line: line + @line_offset, column: column + 1)
        end
      end
    end
  end
end
