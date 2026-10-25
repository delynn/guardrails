# frozen_string_literal: true

require "pathname"
require "prism"
require_relative "erb"

module Guardrails
  module Views
    module Source
      # Reads the inline templates of a ViewComponent file: every
      # `erb_template <<~ERB … ERB` (or `erb_template "…"`) call, through a
      # chain of argument-less calls like `.strip`, hands its raw template,
      # indentation included, to Source::Erb at the lines where it sits, so
      # a finding lands on the right line of the `.rb` file. A one-line
      # string is read unescaped, so its columns drift by the length of
      # each escape before them. A template that interpolates Ruby (`#{…}`)
      # is skipped. Sidecar `.html.erb` templates are ordinary ERB files.
      class ViewComponent
        EXTENSION = ".rb"

        def initialize(root:, path:, content: nil)
          @root = root
          @path = Pathname(root).join(path)
          @relative = path.to_s
          @content = content
        end

        def elements
          program = Prism.parse(@content || File.read(@path, encoding: Encoding::UTF_8)).value
          templates(program).flat_map do |content, line|
            Erb.new(root: @root, path: @relative, content: content, line: line).elements
          end
        end

        private

        # [source, first line] for each `erb_template` argument that is a
        # string without interpolation.
        def templates(node, into = [])
          if node.is_a?(Prism::CallNode) && node.name == :erb_template && node.receiver.nil?
            template = unwrap(node.arguments&.arguments&.first)
            into << [source_of(template), parts_of(template).first.content_loc.start_line] if string?(template)
          end
          node.compact_child_nodes.each { |child| templates(child, into) }
          into
        end

        # `<<~ERB.strip` and the like: the string under a chain of calls.
        def unwrap(node)
          node = node.receiver while node.is_a?(Prism::CallNode) && node.receiver && node.arguments.nil?
          node
        end

        def string?(node)
          parts = parts_of(node)
          !parts.nil? && parts.all?(Prism::StringNode)
        end

        # Prism reads a multi-line squiggly heredoc as an interpolated
        # string made of one plain string per line.
        def parts_of(node)
          case node
          when Prism::StringNode then [node]
          when Prism::InterpolatedStringNode then node.parts
          end
        end

        # A heredoc's raw lines start at column 0, so their slices are the
        # template as written. A plain string is unescaped and padded out
        # to its column so Herb's columns start where the file's do.
        def source_of(template)
          return parts_of(template).map { |part| part.content_loc.slice }.join if template.heredoc?

          (" " * template.content_loc.start_character_column) + template.unescaped
        end
      end
    end
  end
end
