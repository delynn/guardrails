# frozen_string_literal: true

class SampleComponent < Phlex::HTML
  BASE = "rounded w-[3px]"
  TONE = %w[text-gray-500].freeze
  ALIAS = BASE

  def view_template
    div(class: "card #{tone} [anchor-name:--card]", "aria-label": "Card",
      data: { controller: "card", open_at: 1 }, **extra) do
      plain "Hello"
      span(class: [BASE, "px-2", TONE], style: "color: #ff0000") { "World" }
      a(href: "/x", style: { color: "#fff" }) { ok? ? "Yes" : render(Other.new) }
      render Child.new
      img(src: "/i.png", alt: "", title: nil)
      small { plain "Shown"; "Ignored" }
      whitespace
    end
    tag.div(class: "p-[7px]", style: "x")
    content_tag(:section, class: "bg-[#fa3]")
    p("not an element call")
    button { plain label }
    section(class: grid_classes)
    section(class: ALIAS)
  end

  private def grid_classes = "grid grid-cols-[auto_1fr]"
end
