# frozen_string_literal: true

require "tmpdir"
require "fileutils"
require "stringio"
require "guardrails/visual_diff"

RSpec.describe Guardrails::VisualDiff do
  let(:root) { Pathname(Dir.mktmpdir) }
  let(:output) { StringIO.new }
  after do
    FileUtils.rm_rf(root)
    Guardrails.reset_configuration!
  end

  def write_screenshot(relative)
    full = root.join("doc/screenshots").join(relative)
    full.dirname.mkpath
    full.write("fake png bytes for #{relative}")
  end

  describe "#collect via snap_diff adapter (the default)" do
    it "returns empty when the screenshots directory doesn't exist" do
      expect(described_class.new(root: root, output: output).collect).to be_empty
    end

    it "returns empty when there are baselines but no diffs" do
      write_screenshot "homepage.png"
      write_screenshot "checkout/cart.png"

      expect(described_class.new(root: root, output: output).collect).to be_empty
    end

    it "emits one Finding per `*.diff.png` (excluding .heatmap.diff.png)" do
      write_screenshot "homepage.png"
      write_screenshot "homepage.diff.png"
      write_screenshot "homepage.heatmap.diff.png" # excluded — visualization companion

      findings = described_class.new(root: root, output: output).collect
      expect(findings.length).to eq(1)
      expect(findings.first.scenario).to eq("homepage")
    end

    it "scenario name reflects the nested path under the screenshots dir" do
      write_screenshot "checkout/cart.png"
      write_screenshot "checkout/cart.diff.png"

      finding = described_class.new(root: root, output: output).collect.first
      expect(finding.scenario).to eq("checkout/cart")
    end

    it "baseline_path points at the `<name>.png` sibling, diff_path at `<name>.diff.png`" do
      write_screenshot "homepage.png"
      write_screenshot "homepage.diff.png"

      finding = described_class.new(root: root, output: output).collect.first
      expect(finding.baseline_path).to eq("doc/screenshots/homepage.png")
      expect(finding.diff_path).to eq("doc/screenshots/homepage.diff.png")
    end

    it "leaves mismatch_ratio, viewport, url, selector, current_path nil for snap_diff" do
      write_screenshot "homepage.png"
      write_screenshot "homepage.diff.png"

      finding = described_class.new(root: root, output: output).collect.first
      expect(finding.mismatch_ratio).to be_nil
      expect(finding.viewport).to be_nil
      expect(finding.url).to be_nil
      expect(finding.selector).to be_nil
      expect(finding.current_path).to be_nil
    end

    it "honors the Configuration-set snap_diff_dir" do
      # When the user overrides snap_diff_dir via Guardrails.configure,
      # the adapter looks under that path instead of doc/screenshots.
      Guardrails.configure { |c| c.visual_diff.snap_diff_dir = "spec/screenshots" }
      custom = root.join("spec/screenshots/homepage.diff.png")
      custom.dirname.mkpath
      custom.write("fake")
      root.join("spec/screenshots/homepage.png").write("fake")

      findings = described_class.new(root: root, output: output).collect
      expect(findings.length).to eq(1)
    end
  end

  describe "#any_failing?" do
    it "treats nil mismatch_ratio (snap_diff) as unconditionally failing" do
      write_screenshot "homepage.png"
      write_screenshot "homepage.diff.png"

      audit = described_class.new(root: root, output: output)
      expect(audit.any_failing?(audit.collect)).to be true
    end

    it "returns false on an empty findings list" do
      audit = described_class.new(root: root, output: output)
      expect(audit.any_failing?([])).to be false
    end

    it "respects an explicit numeric threshold for adapters that emit a ratio" do
      f_low  = described_class::Finding.new(scenario: "a", mismatch_ratio: 0.01)
      f_high = described_class::Finding.new(scenario: "b", mismatch_ratio: 0.50)

      audit = described_class.new(root: root, output: output, threshold: 0.10)
      expect(audit.any_failing?([f_low])).to be false
      expect(audit.any_failing?([f_high])).to be true
    end
  end

  describe "#run (report output)" do
    it "is silent when there are no findings" do
      described_class.new(root: root, output: output).run
      expect(output.string).to eq("")
    end

    it "prints a header summary plus per-finding details" do
      write_screenshot "homepage.png"
      write_screenshot "homepage.diff.png"

      described_class.new(root: root, output: output).run
      expect(output.string).to include("visual diff (1 finding")
      expect(output.string).to include("adapter: snap_diff")
      expect(output.string).to include("threshold: 0.0")
      expect(output.string).to include("[diff present] homepage")
      expect(output.string).to include("baseline: doc/screenshots/homepage.png")
      expect(output.string).to include("diff:     doc/screenshots/homepage.diff.png")
    end

    it "prints mismatch percentages for findings with a numeric ratio" do
      f = described_class::Finding.new(scenario: "checkout", mismatch_ratio: 0.0237,
                                       diff_path: "tmp/diff.png", viewport: "desktop")
      audit = described_class.new(root: root, output: output)
      audit.send(:print_report, [f])
      expect(output.string).to include("[2.37% mismatch]")
      expect(output.string).to include("checkout (desktop)")
    end
  end

  describe "unknown adapters" do
    it "raises naming the registered adapters when the configured one isn't registered" do
      Guardrails.configure { |c| c.visual_diff.adapter = :backstop }
      audit = described_class.new(root: root, output: output)

      expect { audit.collect }
        .to raise_error(ArgumentError, "Unknown visual_diff adapter: :backstop; registered: [:snap_diff]")
    end

    it "registers snap_diff by default" do
      expect(described_class.adapters).to eq([:snap_diff])
    end
  end

  describe ".register_adapter" do
    # Registration is process-wide; put the registry back afterwards.
    around do |example|
      saved = described_class.instance_variable_get(:@adapters).dup
      example.run
    ensure
      described_class.instance_variable_set(:@adapters, saved)
    end

    let(:fake_adapter) do
      Class.new do
        def initialize(findings) = @findings = findings
        def collect = @findings
      end
    end

    it "builds a registered adapter with the root and the visual_diff config" do
      received = nil
      described_class.register_adapter(:fake) do |root:, config:|
        received = [root, config]
        fake_adapter.new([])
      end

      described_class.new(root: root, output: output, adapter: :fake).collect

      expect(received).to eq([root, Guardrails.configuration.visual_diff])
      expect(described_class.adapters).to include(:fake)
    end

    it "requires a block" do
      expect { described_class.register_adapter(:fake) }.to raise_error(ArgumentError, /needs a block/)
    end

    it "carries an adapter's status, comment, regions and extra details into the report" do
      finding = described_class::Finding.new(
        scenario: "/pricing@desktop+light", mismatch_ratio: nil, status: "changed",
        comment: "Footer wraps at 390px", regions: [{ x: 16, y: 212, w: 358, h: 44 }, { "x" => 0, "y" => 0, "w" => 8, "h" => 8 }],
        baseline_path: "spec/visual/baselines/pricing/desktop+light.png",
        extra_details: [["mismatch", "3.1%"]]
      )
      described_class.register_adapter(:fake) { |root:, config:| fake_adapter.new([finding]) }
      audit = described_class.new(root: root, output: output, adapter: :fake)

      report = audit.categories(audit.collect).first.findings.first

      expect(report.title).to eq("[changed] /pricing@desktop+light")
      expect(report.details).to include(["status", "changed"], ["comment", "Footer wraps at 390px"],
                                        ["regions", "16,212 358x44; 0,0 8x8"], ["mismatch", "3.1%"])
      expect(audit.any_failing?([finding])).to be true
    end
  end

  describe "constructor coercion" do
    # Mirrors what Configuration setters do — passing strings from a
    # CLI / env-var path should behave the same as setting them via
    # Guardrails.configure.
    it "coerces a string adapter to a symbol" do
      write_screenshot "homepage.png"
      write_screenshot "homepage.diff.png"

      audit = described_class.new(root: root, output: output, adapter: "snap_diff")
      expect(audit.collect.length).to eq(1)
    end

    it "coerces a string threshold to a Float" do
      f = described_class::Finding.new(scenario: "x", mismatch_ratio: 0.05)
      audit = described_class.new(root: root, output: output, threshold: "0.10")
      expect(audit.any_failing?([f])).to be false
    end
  end
end
