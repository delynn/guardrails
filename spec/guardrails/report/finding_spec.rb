# frozen_string_literal: true

require "guardrails/report/finding"

RSpec.describe Guardrails::Report::Finding do
  describe "#to_h" do
    it "keeps details with unique labels as scalars" do
      finding = described_class.new(title: "x", details: [["baseline", "a.png"], ["diff", "a.diff.png"]])

      expect(finding.to_h[:details]).to eq("baseline" => "a.png", "diff" => "a.diff.png")
    end

    it "collects a repeated label's values into an array instead of keeping only the last" do
      finding = described_class.new(title: "x", details: [["screenshot", "desktop.png"], ["diff", "d.png"],
                                                          ["screenshot", "mobile.png"]])

      expect(finding.to_h[:details]).to eq("screenshot" => ["desktop.png", "mobile.png"], "diff" => "d.png")
    end
  end
end
