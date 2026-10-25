# frozen_string_literal: true

require "guardrails/views_audit"
require "tmpdir"
require "stringio"
require "fileutils"

RSpec.describe Guardrails::ViewsAudit do
  let(:root) { Pathname(Dir.mktmpdir) }
  let(:output) { StringIO.new }
  let(:audit) { described_class.new(root:, output:) }

  after { FileUtils.remove_entry(root) }

  def write(relative, content)
    path = root.join(relative)
    FileUtils.mkdir_p(path.dirname)
    File.write(path, content)
  end

  it "reports findings with attribute-level locations and prints a section per rule" do
    write("app/components/card.rb", <<~RUBY)
      class Card
        def view_template
          div(class: "p-4 text-[14px]", style: "color: #ff0000")
        end
      end
    RUBY

    findings = audit.run
    expect(findings.map(&:title)).to eq([
      "views tailwind_arbitrary: text-[14px]",
      "views raw_color: #ff0000",
      "views inline_style: style",
    ])
    expect(findings.map { |finding| finding.location.to_s }).to eq(
      ["app/components/card.rb:3:21", "app/components/card.rb:3:50", "app/components/card.rb:3:35"]
    )
    expect(findings.map(&:severity)).to eq(%i[error error warning])
    expect(output.string).to include("views tailwind_arbitrary (1)")
  end

  it "never reaches comments, array literals, constants that are not attributes, or non-colour attributes" do
    write("app/views/show.rb", <<~RUBY)
      # a comment mentioning w-[13px] and #abcdef
      ROWS = [a: 1]
      LINE = "#0ea5e9"
      meta(name: "theme-color", content: "#ffffff")
      a(href: "#top", class: "text-gray-500") { "Top" }
    RUBY

    expect(audit.run).to be_empty
  end

  it "honours a rule-named escape on the finding's line or a comment line above, and nothing else" do
    write("app/views/show.rb", <<~RUBY)
      # guardrails-ok: tailwind_arbitrary safe-area inset has no token
      div(class: "pt-[env(safe-area-inset-top)]")
      span(style: "width: 10%") # guardrails-ok: inline_style computed
      # guardrails-ok: inline_style named the wrong rule
      div(class: "w-[13px]")
      span(style: "x") # guardrails-ok: inline_style only this line
      span(style: "y")
      button(
        class: "x",
        # guardrails-ok: inline_style the escape sits above the attribute, not the element
        style: "z"
      ) { "Go" }
    RUBY

    expect(audit.run.map(&:title)).to eq(["views tailwind_arbitrary: w-[13px]", "views inline_style: style"])
  end

  it "skips a rule for files listed under allow_files in guardrails.yml" do
    write("guardrails.yml", <<~YAML)
      guardrails:
        views:
          allow_files:
            raw_color: [app/components/line.rb]
    YAML
    write("app/components/line.rb", %(div(fill: "#0ea5e9", class: "w-[3px]")\n))

    expect(audit.run.map(&:title)).to eq(["views tailwind_arbitrary: w-[3px]"])
  end

  it "runs the accessibility rules with the file's labels as context" do
    write("guardrails.yml", "guardrails:\n  views:\n    label_wrappers: [labeled]\n")
    write("app/views/form.rb", <<~RUBY)
      label(for: "q") { "Query" }
      input(type: "search", id: "q")
      label { plain "Pick"; input(type: "radio", name: "pick") }
      labeled("Amount") { input(type: "number", name: "amount") }
      input(type: "text", placeholder: "bare")
      img(src: "/x.png")
      button(class: "icon-only")
      a(href: "/x") { label_text }
    RUBY

    expect(audit.run.map(&:title)).to eq(
      ["views image_alt: img", "views button_name: button", "views input_label: input"]
    )
  end

  it "reads only the Phlex sources unless guardrails.yml enables the ERB and ViewComponent sources" do
    write("app/views/show.html.erb", %(<div class="w-[1px]"></div>\n))
    write("app/components/card.rb", <<~RUBY)
      class Card
        erb_template <<~ERB
          <div class="w-[2px]">
            <%# guardrails-ok: tailwind_arbitrary the escape reads as an ERB comment %>
            <span class="w-[3px]"></span>
          </div>
        ERB
      end
    RUBY
    expect(audit.run).to be_empty

    write("guardrails.yml", "guardrails:\n  views:\n    sources: [ruby, erb, view_component]\n")
    findings = described_class.new(root:, output:).run
    expect(findings.map { |finding| [finding.title, finding.location.to_s] }).to eq([
      ["views tailwind_arbitrary: w-[2px]", "app/components/card.rb:3:17"],
      ["views tailwind_arbitrary: w-[1px]", "app/views/show.html.erb:1:13"],
    ])
  end

  it "refuses an unknown source name, an empty list, and reads a repeated source once" do
    write("guardrails.yml", "guardrails:\n  views:\n    sources: [haml]\n")
    expect { audit.run }.to raise_error(ArgumentError, /unknown view source "haml"/)

    write("guardrails.yml", "guardrails:\n  views:\n    sources: []\n")
    expect { described_class.new(root:, output:).run }.to raise_error(ArgumentError, /lists no source/)

    write("guardrails.yml", "guardrails:\n  views:\n    sources: [ruby, ruby]\n")
    write("app/views/show.rb", %(div(style: "x")\n))
    expect(described_class.new(root:, output:).run.length).to eq(1)
  end

  it "prints nothing when clean" do
    expect(audit.run).to be_empty
    expect(output.string).to be_empty
  end
end
