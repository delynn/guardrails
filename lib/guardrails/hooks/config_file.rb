# frozen_string_literal: true

require "json"
require "pathname"

module Guardrails
  module Hooks
    # Adds Guardrails' hook commands to an agent's JSON config without
    # touching anything else in it: other settings, and other hooks on
    # the same events, stay as they were. Running it twice changes
    # nothing the second time.
    class ConfigFile
      attr_reader :path

      def initialize(path)
        @path = Pathname(path)
      end

      # `entries` maps an event name to the list entries to add under
      # `hooks.<event>` (each a Hash in the agent's own shape). An entry
      # counts as present when one with the same command is there.
      # `extra` merges top-level keys that must be set (Cursor's
      # `version`). Returns true when the file changed.
      def add(entries, extra: {})
        config = read
        before = JSON.generate(config)
        extra.each { |key, value| config[key] = value unless config.key?(key) }
        hooks = (config["hooks"] ||= {})
        raise Error, "#{@path}: `hooks` isn't an object" unless hooks.is_a?(Hash)

        entries.each do |event, list|
          existing = (hooks[event] ||= [])
          raise Error, "#{@path}: `hooks.#{event}` isn't a list" unless existing.is_a?(Array)

          list.each { |entry| existing << entry unless commands(existing).include?(command(entry)) }
        end
        return false if JSON.generate(config) == before

        @path.dirname.mkpath
        @path.write("#{JSON.pretty_generate(config)}\n")
        true
      end

      private

      def read
        return {} unless @path.file?

        text = @path.read
        return {} if text.strip.empty?

        config = JSON.parse(text)
        raise Error, "#{@path} isn't a JSON object" unless config.is_a?(Hash)

        config
      rescue JSON::ParserError => e
        raise Error, "#{@path} isn't valid JSON (#{e.message.lines.first.strip}); fix it or add the hooks by hand"
      end

      # Commands in a list of entries, flat (`{"command": ...}`) or
      # grouped (`{"matcher": ..., "hooks": [{"command": ...}]}`).
      def commands(list)
        list.flat_map { |entry| entry.is_a?(Hash) ? [entry["command"], *Array(entry["hooks"]).map { |h| h["command"] if h.is_a?(Hash) }] : [] }.compact
      end

      def command(entry)
        entry["command"] || Array(entry["hooks"]).filter_map { |h| h["command"] }.first
      end
    end
  end
end
