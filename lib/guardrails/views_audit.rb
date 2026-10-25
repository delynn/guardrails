# frozen_string_literal: true

require "pathname"
require_relative "audit"
require_relative "report/style"
require_relative "report/finding"
require_relative "report/severity"
require_relative "views/config"
require_relative "views/escapes"
require_relative "views/rules"
require_relative "views/source/erb"
require_relative "views/source/ruby"
require_relative "views/source/view_component"

module Guardrails
  # View drift and static a11y over views Audit and A11yAudit cannot read:
  # Phlex classes, `tag.*` and `content_tag` helpers, and ViewComponent
  # inline templates. Each source (Guardrails::Views::Source) turns a file
  # into a parser-agnostic element tree (Guardrails::Views::Element) and the
  # rules (Guardrails::Views::Rules) run over the tree, so a rule never sees
  # a parser node and a new template language is a new source.
  #
  # `guardrails.views.sources` picks the sources: `ruby` (the default),
  # `erb` (Herb over `.erb` files; the same rules Audit and A11yAudit
  # already apply, so expect both to report), and `view_component`
  # (`erb_template` heredocs in `.rb` files).
  class ViewsAudit
    SOURCES = {
      "ruby" => Views::Source::Ruby,
      "erb" => Views::Source::Erb,
      "view_component" => Views::Source::ViewComponent
    }.freeze

    def initialize(root:, output: $stdout, style: nil, min_severity: Report::Severity::DEFAULT)
      @root = Pathname(root)
      @output = output
      @style = style || Report::Style.new(io: output)
      @min_severity = min_severity
      @config = Views::Config.new(root: @root)
      @escapes = Views::Escapes.new(root: @root)
    end

    # Every finding across the scan paths, file by file and rule by rule
    # within a file, as Report::Findings. Prints its own report section.
    def run
      findings = view_files.flat_map { |path| findings_in(path) }
      print_report(findings)
      findings
    end

    # One Category per rule, in rule order.
    def categories(findings)
      rules.filter_map do |rule|
        matched = findings.select { |finding| finding.category == category_name(rule) }
        next if matched.empty?

        Report::Category.new(name: category_name(rule), severity: rule.severity,
                             framing: rule.framing, findings: matched)
      end
    end

    # One file's findings without printing. `content` scans a version
    # that isn't on disk (see Audit#scan_source).
    def scan_source(path, content = nil)
      relative = relative(path)
      @escapes.read(relative, content) if content
      findings_in(relative, content)
    end

    # Whether a full run would scan this file.
    def covers?(path)
      relative = relative(path)
      sources.any? { |source| relative.end_with?(source::EXTENSION) } &&
        @config.scan_paths.any? { |dir| relative.start_with?("#{dir}/") } && !ignored?(relative)
    end

    private

    def view_files
      extensions = sources.map { |source| source::EXTENSION }.uniq
      patterns = @config.scan_paths.product(extensions).map { |dir, extension| "#{dir}/**/*#{extension}" }
      Dir.glob(patterns, base: @root).sort.reject { |path| ignored?(path) }
    end

    def sources
      @sources ||= begin
        names = @config.sources
        unknown = names - SOURCES.keys
        choices = "choose from #{SOURCES.keys.join(", ")}"
        raise ArgumentError, "unknown view source #{unknown.first.inspect}; #{choices}" if unknown.any?
        raise ArgumentError, "guardrails.views.sources lists no source; #{choices}" if names.empty?

        names.map { |name| SOURCES.fetch(name) }
      end
    end

    def rules
      @rules ||= Views::Rules.all.select { |rule| Report::Severity.include?(rule.severity, @min_severity) }
    end

    def sources_for(path, content)
      sources.select { |source| path.end_with?(source::EXTENSION) }.map do |source|
        options = source == Views::Source::Ruby ? { label_wrappers: @config.label_wrappers } : {}
        source.new(root: @root, path: path, content: content, **options)
      end
    end

    def findings_in(path, content = nil)
      elements = sources_for(path, content).flat_map(&:elements).flat_map { |element| element.each_element.to_a }
      context = Views::Rules::Context.for(elements)
      rules.reject { |rule| @config.allowed?(rule, path) }.flat_map do |rule|
        elements.flat_map { |element| rule.hits(element, context) }
          .reject { |hit| @escapes.escaped?(rule, hit.location) }
          .map { |hit| finding(rule, hit) }
      end
    end

    def finding(rule, hit)
      Report::Finding.new(
        category: category_name(rule), severity: rule.severity,
        title: "#{category_name(rule)}: #{hit.match}", suggestion: rule.suggestion,
        snippet: @escapes.source_line(hit.location), locations: [hit.location.to_report]
      )
    end

    def category_name(rule)
      "views #{rule.name}"
    end

    # The same implicit and configured ignores Audit applies.
    def ignored?(relative)
      segments = relative.split("/")
      return true if (Audit::IMPLICIT_IGNORE & segments).any?
      return true if segments.any? { |seg| Audit::IMPLICIT_IGNORE_PATTERNS.any? { |pat| seg.match?(pat) } }

      @config.ignore.any? { |ignore| relative == ignore || relative.start_with?("#{ignore}/") }
    end

    def relative(path)
      Pathname(path).expand_path(@root).relative_path_from(@root).to_s
    end

    def print_report(findings)
      categories(findings).each do |category|
        @output.puts ""
        @output.puts @style.section_heading(category.severity, "#{category.name} (#{category.count})")
        @output.puts "  #{category.framing}"
        category.findings.each do |finding|
          @output.puts ""
          @output.puts "  #{@style.severity(finding.severity, finding.title)}"
          @output.puts "    #{@style.suggestion(finding.suggestion)}"
          @output.puts "    #{@style.location(finding.location.to_s)}"
          @output.puts "    #{finding.snippet}"
        end
      end
    end
  end
end
