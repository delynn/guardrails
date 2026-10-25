# frozen_string_literal: true

require "guardrails/views_audit"

RSpec.describe Guardrails::Views::Source::Ruby do
  let(:root) { Pathname(File.expand_path("../../../fixtures", __dir__)) }
  let(:elements) { described_class.new(root:, path: "views/sample_component.rb").elements }
  let(:card) { elements.first }

  it "reads Phlex element calls, tag.* helpers, and content_tag into a tree" do
    expect(elements.map(&:tag)).to eq(%w[div div section button section section])
    expect(card.elements.map(&:tag)).to eq(%w[span a img small])
    expect(card.location.to_s).to eq("views/sample_component.rb:9:5")
  end

  it "normalises attribute names the way Phlex does and flattens data hashes" do
    expect(card.attributes.map(&:name)).to eq(%w[class aria-label data-controller data-open-at])
    expect(card["data-controller"].static_value).to eq("card")
    expect(card["data-open-at"].static_value).to eq("1")
    expect(card.splat).to be(true)
  end

  it "splits interpolated strings into static and dynamic parts with exact locations" do
    parts = card["class"].parts
    expect(parts.map(&:class)).to eq([Guardrails::Views::Static, Guardrails::Views::Dynamic, Guardrails::Views::Static])
    expect(parts.first.text).to eq("card ")
    expect(parts.first.location.to_s).to eq("views/sample_component.rb:9:17")
    expect(parts.last.text).to eq(" [anchor-name:--card]")
    expect(card["class"]).to be_dynamic
  end

  it "resolves constants assigned a literal in the same file, including frozen ones and arrays" do
    span = card.elements.first
    expect(span["class"].static_parts.map(&:text)).to eq(["rounded w-[3px]", "px-2", "text-gray-500"])
    expect(span["class"].static_parts.first.location.to_s).to eq("views/sample_component.rb:4:11")
    expect(span["class"]).not_to be_dynamic
  end

  it "resolves an argument-less method whose body is a literal" do
    expect(elements[4]["class"].static_value).to eq("grid grid-cols-[auto_1fr]")
    expect(elements[4]["class"].static_parts.first.location.line).to eq(27)
  end

  it "keeps a style hash as one computed attribute, the way Phlex renders it" do
    link = card.elements[1]
    expect(link.attributes.map(&:name)).to eq(%w[href style])
    expect(link["style"]).to be_dynamic
  end

  it "does not resolve a constant that aliases another constant" do
    expect(elements[5]["class"]).to be_dynamic
  end

  it "collects visible text from plain and block values, through the branches of a conditional" do
    expect(card.visible_text).to eq("Hello World Yes Shown")
    expect(card.elements[1].visible_text).to eq("Yes")
  end

  it "treats a non-text branch of a conditional as dynamic content" do
    expect(card.elements[1]).to be_dynamic_content
  end

  it "ignores a block value once the block has already written output" do
    expect(card.elements.last.visible_text).to eq("Shown")
    expect(card.elements.last).not_to be_dynamic_content
  end

  it "marks rendered components and computed text as dynamic content" do
    expect(card).to be_dynamic_content
    expect(card.elements.first).not_to be_dynamic_content
    expect(elements[3].visible_text).to eq("")
    expect(elements[3]).to be_dynamic_content
  end

  it "keeps an empty static attribute distinct from a missing one, and nil as unreadable" do
    img = card.elements[2]
    expect(img["alt"].static_value).to eq("")
    expect(img["alt"]).not_to be_dynamic
    expect(img["title"]).to be_dynamic
    expect(img["hidden"]).to be_nil
  end

  it "reads tag.* and content_tag attributes like Phlex attributes" do
    expect(elements[1]["class"].static_value).to eq("p-[7px]")
    expect(elements[1]["style"]).not_to be_nil
    expect(elements[2]["class"].static_value).to eq("bg-[#fa3]")
  end
end
