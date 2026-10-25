# frozen_string_literal: true

require "pathname"

module Guardrails
  module Views
    # `# guardrails-ok: <rule> <reason>` (in ERB, `<%# guardrails-ok: … %>`)
    # at the end of the finding's line or as a comment on the line above
    # silences one finding, the convention the emoji scan uses. Also reads
    # the source line a finding points at, for its snippet.
    class Escapes
      def initialize(root:)
        @root = Pathname(root)
        @lines = {}
      end

      # +content+ replaces the file on disk for +file+ (see ViewsAudit#scan_source).
      def read(file, content)
        @lines[file] = content.lines(chomp: true)
      end

      def escaped?(rule, location)
        marker = /guardrails-ok:\s*#{rule.name}\b/
        lines = lines_of(location.file)
        return true if marker.match?(lines[location.line - 1].to_s)

        above = location.line >= 2 && lines[location.line - 2]
        above && comment?(above) && marker.match?(above)
      end

      def source_line(location)
        lines_of(location.file)[location.line - 1].to_s.strip
      end

      private

      def comment?(line)
        line.lstrip.start_with?("#", "<%#")
      end

      def lines_of(file)
        @lines[file] ||= File.readlines(@root.join(file), chomp: true, encoding: Encoding::UTF_8)
      end
    end
  end
end
