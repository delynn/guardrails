# frozen_string_literal: true

require "tmpdir"
require "guardrails/report/run"
require "guardrails/report/html"

RSpec.describe Guardrails::Report::Detectors do
  # A minimal outside detector: one suggestion-level finding, switched
  # on by FAKE_HEURISTICS=1, failing only when told to.
  let(:detector_class) do
    Class.new do
      class << self
        attr_accessor :built, :fail

        def enabled?(env:) = env["FAKE_HEURISTICS"] == "1"
        def max_severity = :suggestion
      end

      def initialize(root:, output:, style:)
        self.class.built = (self.class.built || 0) + 1
        @output = output
      end

      def run
        @output.puts "Heuristics: 1 finding"
        [{ criterion: "H4.1", title: "Two primary buttons on one view" }]
      end

      def categories(result)
        findings = result.map do |r|
          Guardrails::Report::Finding.new(category: "heuristics", severity: :suggestion, title: r[:title],
                                          details: [["criterion", r[:criterion]]])
        end
        [Guardrails::Report::Category.new(name: "heuristics", severity: :suggestion, findings: findings)]
      end

      def summary_entry(result)
        Guardrails::Report::Summary::Entry.new(category: "heuristics", count: result.length, severity: :suggestion)
      end

      def to_h(result) = { findings: result }
      def failing?(result) = result.any? && self.class.fail == true
    end
  end

  let(:root) { Dir.mktmpdir }

  before { described_class.register(:heuristics, detector_class) }

  after do
    described_class.unregister(:heuristics)
    FileUtils.remove_entry(root)
  end

  def run(env)
    Guardrails::Report::Run.from_env(root: root, env: env).call
  end

  it "runs a registered detector the environment enables, after the built-ins" do
    result = run("FAKE_HEURISTICS" => "1")

    expect(result.body).to end_with("Heuristics: 1 finding\n")
    expect(result.summary_entries.last).to have_attributes(category: "heuristics", count: 1, severity: :suggestion)
    expect(result.categories.map(&:name)).to include("heuristics")
    expect(result.findings.find { |f| f.category == "heuristics" }.to_h[:details]).to eq("criterion" => "H4.1")
  end

  it "reaches the HTML report through its categories" do
    result = run("FAKE_HEURISTICS" => "1")
    html = Guardrails::Report::Html.new(categories: result.categories, root: root).render

    expect(html).to include("Two primary buttons on one view")
  end

  it "puts its JSON under extensions and leaves the built-in keys alone" do
    payload = run("FAKE_HEURISTICS" => "1").to_h

    expect(payload[:extensions]).to eq(heuristics: { findings: [{ criterion: "H4.1", title: "Two primary buttons on one view" }] })
    expect(payload.keys.first(10)).to eq(
      %i[summary violations stimulus similar_partials view_components a11y a11y_deep patterns classitis visual_diff]
    )
  end

  it "leaves the run untouched when the environment doesn't enable it" do
    result = run({})

    expect(detector_class.built).to be_nil
    expect(result.to_h).not_to have_key(:extensions)
    expect(result.summary_entries.map(&:category)).not_to include("heuristics")
  end

  it "isn't built when SEVERITY= is above everything it can report" do
    run("FAKE_HEURISTICS" => "1", "SEVERITY" => "warning")

    expect(detector_class.built).to be_nil
  end

  it "fails the audit only by its own rule" do
    expect(run("FAKE_HEURISTICS" => "1")).not_to be_failing

    detector_class.fail = true
    expect(run("FAKE_HEURISTICS" => "1")).to be_failing
  end

  it "refuses a class missing part of the interface" do
    incomplete = Class.new do
      def self.enabled?(env:) = true
      def self.max_severity = :suggestion
      def run = []
    end

    expect { described_class.register(:broken, incomplete) }
      .to raise_error(ArgumentError, /missing #categories, #summary_entry, #to_h, #failing\?/)
  end

  it "refuses a max_severity that isn't a severity" do
    loud = Class.new(detector_class) { def self.max_severity = :critical }

    expect { described_class.register(:loud, loud) }.to raise_error(ArgumentError, /max_severity must be one of/)
  end
end
