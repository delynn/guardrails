# frozen_string_literal: true

require "guardrails/views_audit"

RSpec.describe Guardrails::Views::Source::Erb do
  let(:root) { Pathname(File.expand_path("../../../fixtures", __dir__)) }
  let(:elements) { described_class.new(root:, path: "views/sample.html.erb").elements }
  let(:card) { elements.first }

  it "reads HTML elements into a tree, walking through ERB control flow and block helpers" do
    expect(elements.map(&:tag)).to eq(%w[div p section footer])
    expect(card.elements.map(&:tag)).to eq(%w[span a img button button label input input p button input])
    expect(card.location.to_s).to eq("views/sample.html.erb:2:1")
  end

  it "splits attribute values into static and dynamic parts with exact locations" do
    expect(card.attributes.map(&:name)).to eq(%w[class id data-controller])
    parts = card["class"].parts
    expect(parts.map(&:class)).to eq([Guardrails::Views::Static, Guardrails::Views::Dynamic])
    expect(parts.first.text).to eq("card ")
    expect(parts.first.location.to_s).to eq("views/sample.html.erb:2:13")
    expect(parts.last.code).to eq("tone")
    expect(card["id"]).to be_dynamic
    expect(card["data-controller"].static_value).to eq("card")
  end

  it "reads the literals inside control flow in a value and drops ERB comments there" do
    note = card.elements.last
    expect(note["id"].static_parts.map(&:text)).to eq(%w[n -long])
    expect(note["id"]).not_to be_dynamic
  end

  it "marks an element with ERB in its open tag, or a computed attribute name, as a splat" do
    expect(card.splat).to be(true)
    named = card.elements[8]
    expect(named.splat).to be(true)
    expect(named.attributes).to be_empty
    expect(elements[1].splat).to be(false)
  end

  it "reads every branch of a conditional open tag as one splatted element" do
    section = elements[2]
    expect(section.attributes.map(&:static_value)).to eq(%w[w-[8px] w-[9px]])
    expect(section.splat).to be(true)
  end

  it "reads an open tag without a close tag as an element whose body is unknown" do
    footer = elements.last
    expect(footer["class"].static_value).to eq("w-[10px]")
    expect(footer).to be_dynamic_content
  end

  it "keeps a multi-line attribute value as one static part per line, newlines included" do
    span = card.elements.first
    expect(span["class"].static_parts.map(&:text)).to eq(["rounded w-[3px]\n", "    px-2"])
    expect(span["class"].static_parts.map { |part| part.location.to_s })
      .to eq(["views/sample.html.erb:3:16", "views/sample.html.erb:4:1"])
  end

  it "reads an empty or valueless attribute as present and empty" do
    expect(card.elements[2]["alt"].parts).to be_empty
    expect(card.elements[7]["disabled"].parts).to be_empty
  end

  it "collects visible text and treats `<%= %>` output as dynamic content" do
    link = card.elements[1]
    expect(link.visible_text).to eq("")
    expect(link).to be_dynamic_content
    expect(card.elements[3].visible_text).to eq("Open")
    expect(card.elements[4]["aria-label"].static_value).to eq("Close")
    expect(card.visible_text).to eq("Hello Open Search Named")
  end

  it "drops HTML and ERB comments, even one holding `<%= %>`, and `<% %>` statements" do
    codes = card.children.grep(Guardrails::Views::Dynamic).map(&:code)
    expect(codes).to eq(["render Card::Footer.new", "form_with(url: \"/\") do |f|"])
    expect(card.elements[9]).not_to be_dynamic_content
    expect(card.each_element.flat_map { |element| element.children.grep(Guardrails::Views::Static).map(&:text) })
      .not_to include(a_string_matching(/w-\[13px\]|#abcdef/))
  end

  it "offsets every location when handed an embedded template" do
    source = described_class.new(root:, path: "app/components/x.rb", content: "  <p>Hi</p>\n", line: 7)
    expect(source.elements.first.location.to_s).to eq("app/components/x.rb:7:3")
  end
end
