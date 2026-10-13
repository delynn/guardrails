# frozen_string_literal: true

module Guardrails
  module Hooks
    # One per coding agent: where its hook config lives, which of its
    # events map to Guardrails' edit / stop / session_start, how to read
    # its hook input, and the exact output shape it expects. The shapes
    # differ enough (Codex rejects unknown keys, Cursor continues a turn
    # with `followup_message`) that each agent gets its own.
    module Adapters
      # Claude Code: `.claude/settings.json`. PostToolUse output reaches
      # the model as `additionalContext`; Stop blocks with
      # `decision: "block"`.
      class Claude
        def name = "claude"
        def config_path = ".claude/settings.json"
        def config_extra = {}

        def config_entries(command)
          {
            "PostToolUse" => [group(command.call("edit"), matcher: "Edit|Write|MultiEdit", timeout: 30)],
            "Stop" => [group(command.call("stop"), timeout: 60)],
            "SessionStart" => [group(command.call("session_start"), matcher: "startup|resume|clear|compact", timeout: 30)]
          }
        end

        # Hook commands run in the session's directory, which may not be
        # the app's; Claude Code and Gemini CLI set the project's.
        def command_prefix = %(cd "$CLAUDE_PROJECT_DIR" && )

        def project_dir(input, env)
          env["CLAUDE_PROJECT_DIR"] || input["cwd"]
        end

        def files(input, _root)
          [input.dig("tool_input", "file_path")].compact
        end

        def continued?(input)
          input["stop_hook_active"] == true
        end

        def output(kind, outcome)
          case kind
          when :stop then outcome.block ? { "decision" => "block", "reason" => outcome.message } : {}
          when :edit then context("PostToolUse", outcome)
          else context("SessionStart", outcome)
          end
        end

        private

        def context(event_name, outcome)
          return {} if outcome.notes.empty?

          { "hookSpecificOutput" => { "hookEventName" => event_name, "additionalContext" => outcome.message } }
        end

        def group(command, matcher: nil, timeout: nil)
          hook = { "type" => "command", "command" => command }
          hook["timeout"] = timeout if timeout
          matcher ? { "matcher" => matcher, "hooks" => [hook] } : { "hooks" => [hook] }
        end
      end

      # Codex CLI: `.codex/hooks.json`, same events and nesting as Claude
      # Code. Every edit is an `apply_patch` call whose input is the raw
      # patch, so file names come from its headers. Codex rejects output
      # keys it doesn't know, and treats empty stdout on Stop as invalid.
      class Codex < Claude
        PATCH_FILE = /^\*\*\* (?:Add File|Update File|Move to): (.+)$/

        def name = "codex"
        def config_path = ".codex/hooks.json"

        def config_entries(command)
          super.merge("PostToolUse" => [group(command.call("edit"), matcher: "^apply_patch$", timeout: 30)])
        end

        # Codex runs hooks in the session's directory; Bundler finds the
        # app's Gemfile from there.
        def command_prefix = ""

        def project_dir(input, _env)
          input["cwd"]
        end

        def files(input, _root)
          patch = input.dig("tool_input", "command")
          return [] unless patch.is_a?(String)

          patch.scan(PATCH_FILE).flatten.map(&:strip).map { |file| File.expand_path(file, input["cwd"] || Dir.pwd) }
        end
      end

      # Cursor: `.cursor/hooks.json` (version 1). Its after-edit output
      # doesn't reliably reach the model, so Cursor gets the stop and
      # session-start hooks; the stop hook covers every template changed
      # since HEAD. `followup_message` becomes the next user message.
      class Cursor
        def name = "cursor"
        def config_path = ".cursor/hooks.json"
        def config_extra = { "version" => 1 }
        def command_prefix = ""

        def config_entries(command)
          {
            "stop" => [{ "command" => command.call("stop"), "timeout" => 60 }],
            "sessionStart" => [{ "command" => command.call("session_start"), "timeout" => 30 }]
          }
        end

        def project_dir(input, env)
          Array(input["workspace_roots"]).first || env["CURSOR_PROJECT_DIR"] || env["CLAUDE_PROJECT_DIR"]
        end

        def files(input, _root)
          [input["file_path"]].compact
        end

        # A turn the user aborted, or one a stop hook already continued,
        # isn't sent back again.
        def continued?(input)
          input["loop_count"].to_i.positive? || (input.key?("status") && input["status"] != "completed")
        end

        def output(kind, outcome)
          case kind
          when :stop then outcome.block ? { "followup_message" => outcome.message } : {}
          else outcome.notes.empty? ? {} : { "additional_context" => outcome.message }
          end
        end
      end

      # Gemini CLI: `.gemini/settings.json`. AfterTool appends
      # `additionalContext` to the tool result; AfterAgent blocks with
      # `decision: "block"`. Timeouts are in milliseconds.
      class Gemini < Claude
        def name = "gemini"
        def config_path = ".gemini/settings.json"
        def command_prefix = %(cd "$GEMINI_PROJECT_DIR" && )

        def config_entries(command)
          {
            "AfterTool" => [group(command.call("edit"), matcher: "write_file|replace", timeout: 30_000)],
            "AfterAgent" => [group(command.call("stop"), timeout: 60_000)],
            "SessionStart" => [group(command.call("session_start"), matcher: "startup|resume|clear", timeout: 30_000)]
          }
        end

        def project_dir(input, env)
          env["GEMINI_PROJECT_DIR"] || input["cwd"]
        end

        def files(input, _root)
          file = input.dig("tool_input", "file_path")
          file ? [File.expand_path(file, input["cwd"] || Dir.pwd)] : []
        end

        def output(kind, outcome)
          case kind
          when :stop then outcome.block ? { "decision" => "block", "reason" => outcome.message } : {}
          else outcome.notes.empty? ? {} : { "hookSpecificOutput" => { "additionalContext" => outcome.message } }
          end
        end

        private

        def group(command, matcher: nil, timeout: nil)
          super.tap { |entry| entry["hooks"].first["name"] = "guardrails" }
        end
      end

      ALL = [Claude.new, Codex.new, Cursor.new, Gemini.new].to_h { |adapter| [adapter.name, adapter] }.freeze

      def self.fetch(name)
        ALL.fetch(name.to_s) do
          raise Error, "Unknown agent #{name.inspect}; expected one of #{ALL.keys.join(", ")}"
        end
      end

      # Cursor also runs the hooks in `.claude/settings.json`, with
      # Cursor's own input. The input says who's calling.
      def self.cursor_input?(input)
        input.key?("cursor_version") || input.key?("conversation_id")
      end
    end
  end
end
