# frozen_string_literal: true

require "pathname"
require "yaml"

module Guardrails
  module Views
    # The `views:` block of guardrails.yml, with the audit's scan paths and
    # ignores as the defaults it shares:
    #
    #     guardrails:
    #       views:
    #         sources: [ruby]            # ruby, erb, view_component
    #         scan_paths: [app/views, app/components]
    #         allow_files:
    #           raw_color: [app/components/legacy_chart.rb]
    #         label_wrappers: [labeled]
    class Config
      DEFAULT_SOURCES = %w[ruby].freeze

      def initialize(root:)
        @root = Pathname(root)
      end

      # Which sources read the views; Ruby (Phlex and tag helpers) only by
      # default, because Audit and A11yAudit already read ERB.
      def sources
        Array(views["sources"] || DEFAULT_SOURCES).map(&:to_s).uniq
      end

      def scan_paths
        Array(views["scan_paths"] || audit["scan_paths"] || Audit::DEFAULT_SCAN_PATHS)
      end

      # `audit.ignore`: exact paths or directory prefixes, as Audit reads them.
      def ignore
        Array(audit["ignore"])
      end

      # Files a rule never reports, per rule name.
      def allowed?(rule, file)
        Array((views["allow_files"] || {})[rule.name]).include?(file)
      end

      # Helpers that render their block inside a label (see Source::Ruby).
      def label_wrappers
        Array(views["label_wrappers"])
      end

      # `guardrails.stimulus.view_patterns`: the templates StimulusAudit
      # reads instead of its defaults, when set.
      def stimulus_view_patterns
        Array((config.fetch("stimulus", {}) || {})["view_patterns"])
      end

      private

      def views
        config.fetch("views", {}) || {}
      end

      def audit
        config.fetch("audit", {}) || {}
      end

      def config
        @config ||= begin
          path = @root.join("guardrails.yml")
          data = path.exist? ? YAML.safe_load_file(path) : nil
          (data || {}).fetch("guardrails", {}) || {}
        rescue StandardError
          {}
        end
      end
    end
  end
end
