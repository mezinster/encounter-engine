require "rails_helper"

# The countdown is JavaScript, so this asserts on the emitted source rather than
# on a rendered number: the arithmetic that was wrong is right here in the
# template, and the frozen features that touch this partial assert the plural
# table's presence in that same source.
RSpec.describe "shared/_countdown", type: :view do
  let(:author) { create_user }
  let(:game)   { create_game(:author => author) }

  before do
    assign(:game, game)
    assign(:team, nil)
    assign(:current_user, author)
    view.define_singleton_method(:current_user) { author }
    view.define_singleton_method(:logged_in?)   { true }
  end

  # THE bug: days came from a calendar date subtraction while hours/minutes/
  # seconds came from the true interval, so "1 day" and "22 hours" were counted
  # from different things and printed together.
  it "derives every component from the interval, not from calendar fields" do
    render :partial => "shared/countdown"

    expect(rendered).not_to include("end.getDate()")
    expect(rendered).not_to include("end.getMonth()")
    expect(rendered).not_to include("end.getYear()")
  end

  it "reduces hours modulo 24, not 60" do
    render :partial => "shared/countdown"

    expect(rendered).not_to match(%r{hours\s*=\s*Math\.floor\([^)]*\)\s*%\s*60})
  end

  # features/games/enter-game-before-start.feature:23,42 assert this whole table
  # via have_text(:all, ...), which reaches inside the <script>. It must keep
  # rendering even though years and months are no longer computed.
  it "still renders the full plural table the frozen features assert" do
    render :partial => "shared/countdown"

    %w[years months days hours minutes seconds].each do |unit|
      expect(rendered).to include("#{unit}:")
    end
    expect(rendered).to include(I18n.t("shared.countdown.years").first)
    expect(rendered).to include(I18n.t("shared.countdown.months").first)
  end
end
