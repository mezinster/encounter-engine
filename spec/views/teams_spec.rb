# -*- encoding : utf-8 -*-
require "rails_helper"

RSpec.describe "teams/new", type: :view do
  # rspec-rails' default helper-guessing only auto-includes a helper module
  # matching the spec's own name (would be TeamsHelper, which doesn't exist)
  # plus ApplicationHelper (also doesn't exist in this app -- see
  # app/helpers/global_helpers.rb's header comment). error_messages_for lives
  # in GlobalHelpers, which a real request includes app-wide via Rails'
  # include_all_helpers default; add it explicitly here so this view spec
  # matches that real-world availability.
  helper GlobalHelpers

  it "renders the new-team form" do
    assign(:team, Team.new)

    render

    expect(rendered).to include(I18n.t("teams.new.name_label"))
    expect(rendered).to include(I18n.t("teams.new.submit"))
    expect(rendered).to include(teams_path)
  end

  it "renders validation errors with the translated header" do
    team = Team.new
    team.valid?
    assign(:team, team)

    render

    expect(rendered).to include(I18n.t("teams.new.error_header"))
  end
end
