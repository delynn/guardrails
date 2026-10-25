# frozen_string_literal: true

require "guardrails/views_audit"

require "set"

RSpec.describe Guardrails::Views::Rules do
  def loc(line = 1, column = 1) = Guardrails::Views::Location.new(file: "x.rb", line:, column:)
  def static(text, column = 1) = Guardrails::Views::Static.new(text:, location: loc(1, column))
  def dynamic = Guardrails::Views::Dynamic.new(code: "x", location: loc)

  def element(tag = "div", children: [], splat: false, **attributes)
    attrs = attributes.map { |name, parts| Guardrails::Views::Attribute.new(name: name.to_s, parts: Array(parts), location: loc) }
    Guardrails::Views::Element.new(tag:, attributes: attrs, children:, location: loc, splat:)
  end

  let(:context) { Guardrails::Views::Rules::Context.new(label_ids: Set["known"], nested_inputs: Set[loc(9)]) }
  def hits(rule, element) = rule.hits(element, context)

  describe described_class::TailwindArbitrary do
    it "flags each arbitrary token at its column and skips dynamic parts" do
      hits = hits(described_class, element(class: [static("a w-[1px] [x:y] b", 10), dynamic]))
      expect(hits.map(&:match)).to eq(["w-[1px]", "[x:y]"])
      expect(hits.map { |hit| hit.location.column }).to eq([12, 20])
    end

    it "does nothing without a class attribute" do
      expect(hits(described_class, element(style: static("x")))).to be_empty
    end
  end

  describe described_class::RawColor do
    it "flags hex and rgb literals only in colour-bearing attributes" do
      hits = hits(described_class, element(style: static("color: #fff; background: rgb(1,2,3)"),
        fill: static("#123456"), "data-line-color": static("#0ea5e9"),
        href: static("#abc"), content: static("#ffffff")))
      expect(hits.map(&:match)).to eq(["#fff", "rgb(1,2,3)", "#123456", "#0ea5e9"])
    end
  end

  describe described_class::ImageAlt do
    it "flags an img without alt, but not an empty alt or a spread it cannot see" do
      expect(hits(described_class, element("img", src: static("/x")))).not_to be_empty
      expect(hits(described_class, element("img", src: static("/x"), alt: static("")))).to be_empty
      expect(hits(described_class, element("img", splat: true))).to be_empty
      expect(hits(described_class, element("div"))).to be_empty
    end
  end

  describe described_class::ButtonName do
    it "wants visible text, an aria name, or rendered content it cannot read" do
      expect(hits(described_class, element("button"))).not_to be_empty
      expect(hits(described_class, element("button", children: [static("Go")]))).to be_empty
      expect(hits(described_class, element("button", "aria-label": static("Go")))).to be_empty
      expect(hits(described_class, element("button", "aria-labelledby": dynamic))).to be_empty
      expect(hits(described_class, element("button", children: [dynamic]))).to be_empty
      expect(hits(described_class, element("button", splat: true))).to be_empty
    end
  end

  describe described_class::LinkName do
    it "only judges links with an href, and accepts a title" do
      expect(hits(described_class, element("a", href: static("/x")))).not_to be_empty
      expect(hits(described_class, element("a"))).to be_empty
      expect(hits(described_class, element("a", href: static("/x"), title: static("T")))).to be_empty
      expect(hits(described_class, element("a", href: static("/x"), children: [static("Go")]))).to be_empty
    end
  end

  describe described_class::InputLabel do
    it "accepts an aria name, a label for its id, nesting inside a label, or a non-interactive type" do
      expect(hits(described_class, element("input"))).not_to be_empty
      expect(hits(described_class, element("input", "aria-label": static("Q")))).to be_empty
      expect(hits(described_class, element("input", id: static("known")))).to be_empty
      expect(hits(described_class, element("input", id: static("unknown")))).not_to be_empty
      expect(hits(described_class, element("input", id: dynamic))).to be_empty
      expect(hits(described_class, element("input", type: static("hidden")))).to be_empty
      nested = Guardrails::Views::Element.new(tag: "input", attributes: [], children: [], location: loc(9), splat: false)
      expect(hits(described_class, nested)).to be_empty
    end
  end

  describe described_class::InlineStyle do
    it "flags a style attribute whether static or computed" do
      expect(hits(described_class, element(style: dynamic)).map(&:match)).to eq(["style"])
      expect(hits(described_class, element(class: static("x")))).to be_empty
    end
  end
end
