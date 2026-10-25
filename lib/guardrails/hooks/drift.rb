# frozen_string_literal: true

require "open3"
require "pathname"
require "stringio"
require_relative "../audit"
require_relative "../a11y_audit"
require_relative "../views_audit"

module Guardrails
  module Hooks
    # The drift a coding agent introduced: what the parse-only checks
    # (Audit, A11yAudit, ViewsAudit) find in a view now, minus what they find in
    # the same file at HEAD. Drift that was already there isn't the
    # agent's to fix unless someone asks, so the hooks never mention it.
    #
    # Lines move as a file is edited, so findings are matched by
    # category and snippet, once per occurrence: a template that had two
    # raw colours at HEAD and has three now has one new one.
    class Drift
      Item = Struct.new(:file, :line, :category, :severity, :title, :suggestion, :snippet, keyword_init: true) do
        def to_s
          text = "#{file}:#{line} #{title}"
          suggestion ? "#{text} (#{suggestion})" : text
        end

        def error?
          severity == :error
        end

        def key
          [category, snippet.to_s.strip]
        end
      end

      def initialize(root:)
        @root = Pathname(root).expand_path
        @audit = Audit.new(root: @root, output: StringIO.new)
        @a11y = A11yAudit.new(root: @root, output: StringIO.new)
        @views = ViewsAudit.new(root: @root, output: StringIO.new)
      end

      # New findings in the given files (absolute or relative to root).
      def introduced(files)
        files.filter_map { |file| relative(file) }.uniq.flat_map { |file| introduced_in(file) }
      end

      # Views changed since HEAD, or untracked, relative to root. Empty
      # outside a git repository.
      def changed_files
        (git("diff", "--name-only", "--relative", "HEAD") + git("ls-files", "--others", "--exclude-standard"))
          .uniq.select { |file| (file.end_with?(".html.erb") || @views.covers?(file)) && @root.join(file).file? }
      end

      private

      def introduced_in(file)
        return [] unless @root.join(file).file?

        now = findings(file, nil)
        return now if now.empty?

        before = head_content(file)
        return now if before.nil?

        remaining = findings(file, before).map(&:key).tally
        now.reject do |item|
          next false unless remaining.fetch(item.key, 0).positive?

          remaining[item.key] -= 1
          true
        end
      end

      def findings(file, content)
        categories = []
        categories += @audit.categories(@audit.scan_source(file, content)) if @audit.covers?(file)
        categories += @a11y.categories(@a11y.scan_source(file, content)) if @a11y.covers?(file)
        categories += @views.categories(@views.scan_source(file, content)) if @views.covers?(file)
        categories.flat_map(&:findings).map do |finding|
          Item.new(file: file, line: finding.location&.line, category: finding.category, severity: finding.severity,
                   title: finding.title, suggestion: finding.suggestion, snippet: finding.snippet)
        end
      end

      def head_content(file)
        out, status = Open3.capture2("git", "show", "HEAD:./#{file}", chdir: @root.to_s, err: File::NULL)
        status.success? ? out.force_encoding(Encoding::UTF_8) : nil
      rescue SystemCallError
        nil
      end

      def git(*args)
        out, status = Open3.capture2("git", *args, chdir: @root.to_s, err: File::NULL)
        status.success? ? out.lines.map(&:chomp).reject(&:empty?) : []
      rescue SystemCallError
        []
      end

      # nil for a file outside the app.
      def relative(file)
        relative = Pathname(file).expand_path(@root).relative_path_from(@root).to_s
        relative unless relative.start_with?("..")
      end
    end
  end
end
