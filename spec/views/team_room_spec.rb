# -*- encoding : utf-8 -*-
require "rails_helper"

RSpec.describe "team_room/index", type: :view do
  it "renders team composition (with the captain marker) and the current-games sections" do
    captain = create_user
    team = create_team(captain: captain)
    captain.reload
    member = create_user
    team.members << member

    assign(:team, team)
    assign(:current_user, captain)
    view.define_singleton_method(:current_user) { captain }
    view.define_singleton_method(:logged_in?) { true }

    render

    expect(rendered).to include(I18n.t("team_room.index.title", name: team.name))
    expect(rendered).to include(I18n.t("team_room.index.composition"))
    expect(rendered).to include("#{captain.nickname} #{I18n.t("team_room.index.captain_suffix")}")
    expect(rendered).to include(member.nickname)
    expect(rendered).to include(I18n.t("team_room.index.invite"))
    expect(rendered).to include(new_invitation_path)
  end
end
