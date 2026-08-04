# -*- encoding : utf-8 -*-
require "rails_helper"

RSpec.describe "teams/new", type: :view do
  # error_messages_for is available here with no explicit `helper`
  # declaration or spec-side stub: it lives in ApplicationHelper
  # (app/helpers/application_helper.rb), which both Rails' real
  # `include_all_helpers` default and rspec-rails' view-spec helper
  # inference (`_default_helpers` checks for the literal `ApplicationHelper`
  # constant) pick up automatically, by naming convention alone. Renamed
  # from GlobalHelpers/global_helpers.rb in Task 9c's fix round 1 -- that
  # name never matched either mechanism, so error_messages_for was
  # genuinely undefined on every real request until the rename (see
  # app/helpers/application_helper.rb's header comment).

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

    expect(rendered).to include(I18n.t("shared.error_header"))
  end
end
