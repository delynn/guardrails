# frozen_string_literal: true

require "pathname"
require_relative "../guardrails"
require_relative "hooks/drift"
require_relative "hooks/config_file"

module Guardrails
  # Coding-agent hooks (Claude Code, Codex, Cursor, Gemini CLI): drift
  # the agent introduces is reported back to it while it works, and it
  # isn't allowed to end its turn with new errors. Adapters translate
  # each agent's hook input and output; the checks here don't know
  # which agent is asking.
  #
  #   - edit: after the agent edits files, the drift it introduced in
  #     them, as context for its next step
  #   - stop: when it tries to finish, new errors in any template
  #     changed since HEAD send it back to work, once
  #   - session_start: context for a new session, from contributors
  #
  # Other gems contribute to the same events with `Hooks.register`
  # (ui_guardrails-browser adds visual-review rejections). A gem ships
  # its contributor at `lib/guardrails/hook_contributors/<name>.rb`,
  # which the runner loads, so hooks work without booting the app.
  module Hooks
    # One hook call, whatever the agent. `continued` is true when a
    # stop hook has already sent the agent back once this turn.
    Event = Struct.new(:kind, :root, :files, :continued, keyword_init: true) do
      def files
        self[:files] || []
      end
    end

    # What to tell the agent. `notes` reach it as context; with
    # `block`, a stop is refused and the notes are the reason.
    Outcome = Struct.new(:notes, :block, keyword_init: true) do
      def self.none
        new(notes: [], block: false)
      end

      def notes
        self[:notes] || []
      end

      def message
        notes.join("\n\n")
      end

      def merge(other)
        return self if other.nil?

        Outcome.new(notes: notes + other.notes, block: block || other.block)
      end
    end

    KINDS = %i[edit stop session_start].freeze

    @contributors = {}

    class << self
      # A contributor answers any of `on_edit(event)`, `on_stop(event)`
      # and `on_session_start(event)` with an Outcome or nil.
      def register(name, contributor)
        @contributors[name.to_sym] = contributor
      end

      def unregister(name)
        @contributors.delete(name.to_sym)
      end

      def contributors
        @contributors.dup
      end

      # Loads contributors shipped by other gems on the load path.
      def load_contributors
        Gem.find_files("guardrails/hook_contributors/*.rb").each { |path| require path }
      end

      def check(event)
        outcome = case event.kind
                  when :edit then on_edit(event)
                  when :stop then on_stop(event)
                  else Outcome.none
                  end
        @contributors.each_value.reduce(outcome) do |result, contributor|
          method = :"on_#{event.kind}"
          contributor.respond_to?(method) ? result.merge(contributor.public_send(method, event)) : result
        end
      end

      private

      def on_edit(event)
        items = Drift.new(root: event.root).introduced(event.files)
        return Outcome.none if items.empty?

        Outcome.new(notes: [describe(items, "Guardrails found drift you just introduced:")], block: false)
      end

      # Sent back once: a second refusal in the same turn could loop on
      # a finding the agent can't fix.
      def on_stop(event)
        return Outcome.none if event.continued

        drift = Drift.new(root: event.root)
        items = drift.introduced(drift.changed_files)
        return Outcome.none unless items.any?(&:error?)

        Outcome.new(notes: [describe(items, "Fix the drift this change introduced before finishing:")], block: true)
      end

      def describe(items, heading)
        lines = items.sort_by { |item| [item.error? ? 0 : 1, item.file, item.line.to_i] }
                     .map { |item| "- [#{item.severity}] #{item}" }
        ([heading] + lines).join("\n")
      end
    end
  end
end
