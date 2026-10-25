# frozen_string_literal: true

require "guardrails/views_audit"

RSpec.describe Guardrails::Views::Source::ViewComponent do
  let(:root) { Pathname(File.expand_path("../../../fixtures", __dir__)) }
  let(:elements) { described_class.new(root:, path: "views/sample_view_component.rb").elements }

  it "reads each erb_template heredoc at the lines and columns where it sits in the file" do
    expect(elements.map(&:tag)).to eq(%w[div span em])
    div = elements.first
    expect(div.location.to_s).to eq("views/sample_view_component.rb:7:5")
    expect(div["class"].static_parts.first.location.to_s).to eq("views/sample_view_component.rb:7:17")
    expect(div).to be_dynamic_content
  end

  it "reads a one-line string template, unescaped, from its column" do
    span = elements[1]
    expect(span.location.to_s).to eq("views/sample_view_component.rb:12:17")
    expect(span["style"].static_value).to eq("color: red")
    expect(span.visible_text).to eq("One line")
  end

  it "reads a heredoc under a chain of calls like .strip" do
    expect(elements.last.location.to_s).to eq("views/sample_view_component.rb:15:5")
    expect(elements.last.visible_text).to eq("Stripped")
  end

  it "skips a template that interpolates Ruby" do
    expect(elements.map(&:tag)).not_to include("p")
  end
end
