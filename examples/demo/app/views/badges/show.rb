# frozen_string_literal: true

# Seeded violations for the views audit (Guardrails::ViewsAudit), which
# reads Phlex classes and tag helpers that the ERB scanners cannot see.
# The same drift as welcome/broken.html.erb, as a Phlex view. Not routed.
class Views::Badges::Show < Phlex::HTML
  # 1. inline_style, and raw_color inside it
  # 2. tailwind_arbitrary, twice
  # 3. image_alt
  # 4. button_name (an icon-only button with no aria-label)
  # 5. link_name
  # 6. input_label (a placeholder is not a label)
  def view_template
    h1(style: "color: #0066ff") { "Drift demo" }
    div(class: "bg-[#fa3] p-[7px]") { "Arbitrary Tailwind values" }
    img(src: "/decoration.png")
    button(class: "icon-only")
    a(href: "/profile")
    input(type: "search", placeholder: "Find a badge")
  end
end
