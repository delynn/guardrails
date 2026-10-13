# frozen_string_literal: true

require "json"
require_relative "../hooks"
require_relative "adapters"

module Guardrails
  module Hooks
    # `guardrails-hook <agent> <event>`: reads the agent's hook input,
    # runs the checks for the event, and answers in the agent's shape.
    #
    # It never breaks the agent's turn. Any failure prints `{}` (every
    # agent accepts it as "nothing to say") with the error on stderr,
    # and exits 0.
    class Runner
      Result = Struct.new(:stdout, :stderr, :exit_code, keyword_init: true)
      EVENTS = { "edit" => :edit, "stop" => :stop, "session_start" => :session_start }.freeze
      QUIET = Result.new(stdout: "{}\n", stderr: "", exit_code: 0).freeze

      def self.call(**kwargs)
        new(**kwargs).call
      end

      def initialize(agent:, event:, stdin:, env: ENV)
        @agent = agent
        @event = event
        @stdin = stdin
        @env = env
      end

      def call
        kind = EVENTS.fetch(@event.to_s) do
          raise Error, "Unknown event #{@event.inspect}; expected #{EVENTS.keys.join(", ")}"
        end
        input = parse(@stdin)
        adapter = adapter_for(input)
        return QUIET unless adapter

        root = root_for(input, adapter)
        event = Event.new(kind: kind, root: root, files: adapter.files(input, root),
                          continued: adapter.continued?(input))
        Hooks.load_contributors
        Result.new(stdout: "#{JSON.generate(adapter.output(kind, Hooks.check(event)))}\n", stderr: "", exit_code: 0)
      rescue StandardError, ScriptError => e
        Result.new(stdout: QUIET.stdout, stderr: "guardrails-hook: #{e.class}: #{e.message}\n", exit_code: 0)
      end

      private

      # Strips the byte-order mark Cursor sends on Windows.
      def parse(text)
        text = text.to_s.dup.force_encoding(Encoding::UTF_8).delete_prefix("﻿")
        return {} if text.strip.empty?

        input = JSON.parse(text)
        input.is_a?(Hash) ? input : {}
      end

      # Cursor runs `.claude/settings.json` hooks too, with its own
      # input. When the project has Cursor hooks of its own, that call
      # is a duplicate and does nothing; otherwise it's answered as
      # Cursor.
      def adapter_for(input)
        adapter = Adapters.fetch(@agent)
        return adapter unless adapter.name != "cursor" && Adapters.cursor_input?(input)

        cursor = Adapters.fetch("cursor")
        root = root_for(input, cursor)
        own = Pathname(root).join(cursor.config_path)
        own.file? && own.read.include?("guardrails-hook") ? nil : cursor
      end

      # The app is where the Gemfile is when run with `bundle exec`;
      # otherwise the agent's project directory.
      def root_for(input, adapter)
        gemfile = @env["BUNDLE_GEMFILE"].to_s
        return Pathname(gemfile).dirname.expand_path unless gemfile.empty?

        Pathname(adapter.project_dir(input, @env) || Dir.pwd).expand_path
      end
    end
  end
end
