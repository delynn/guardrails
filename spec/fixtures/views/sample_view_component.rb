# frozen_string_literal: true

# A fixture for ViewGuardrails::Source::ViewComponent: inline templates in
# the shapes ViewComponent accepts. Not a real component.
class SampleViewComponent
  erb_template <<~ERB
    <div class="card w-[3px]">
      <%= content %>
    </div>
  ERB

  erb_template "<span style=\"color: red\">One line</span>"

  erb_template <<~ERB.strip
    <em>Stripped</em>
  ERB

  erb_template <<~ERB
    <p>#{interpolated}</p>
  ERB

  def initialize(title:) = @title = title
end
