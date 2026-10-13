# frozen_string_literal: true

require "tmpdir"
require "guardrails/hooks"

RSpec.describe Guardrails::Hooks::ConfigFile do
  around { |example| Dir.mktmpdir { |dir| @dir = Pathname(dir); example.run } }

  let(:path) { @dir.join(".claude/settings.json") }
  let(:stop) { { "hooks" => [{ "type" => "command", "command" => "bundle exec guardrails-hook claude stop" }] } }

  it "creates the file with the hooks" do
    expect(described_class.new(path).add({ "Stop" => [stop] })).to be true

    expect(JSON.parse(path.read)).to eq("hooks" => { "Stop" => [stop] })
  end

  it "keeps other settings and other hooks on the same event, and adds nothing twice" do
    theirs = { "hooks" => [{ "type" => "command", "command" => "./bin/notify" }] }
    path.dirname.mkpath
    path.write(JSON.generate("model" => "opus", "hooks" => { "Stop" => [theirs] }))

    file = described_class.new(path)
    expect(file.add({ "Stop" => [stop] })).to be true
    expect(file.add({ "Stop" => [stop] })).to be false

    expect(JSON.parse(path.read)).to eq("model" => "opus", "hooks" => { "Stop" => [theirs, stop] })
  end

  it "handles flat entries and top-level keys the agent needs" do
    cursor = @dir.join(".cursor/hooks.json")
    entry = { "command" => "bundle exec guardrails-hook cursor stop" }

    described_class.new(cursor).add({ "stop" => [entry] }, extra: { "version" => 1 })
    expect(described_class.new(cursor).add({ "stop" => [entry] }, extra: { "version" => 1 })).to be false

    expect(JSON.parse(cursor.read)).to eq("version" => 1, "hooks" => { "stop" => [entry] })
  end

  it "refuses to rewrite a file it can't read as a JSON object" do
    path.dirname.mkpath
    path.write("{ not json")

    expect { described_class.new(path).add({ "Stop" => [stop] }) }.to raise_error(Guardrails::Error, /isn't valid JSON/)
    expect(path.read).to eq("{ not json")
  end
end
