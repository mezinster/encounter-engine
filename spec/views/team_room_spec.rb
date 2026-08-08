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
    # TeamRoomController#index always assigns this -- empty for anyone who is
    # not the captain -- so a view spec that omits it is testing a state the
    # app cannot produce.
    assign(:join_requests, [])
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

  # The captain's inbox for join requests (S4). Captain-only, which is what
  # keeps it clear of the frozen "Не капитан" scenario in
  # features/games/registration-to-game.feature that asserts a non-captain
  # sees neither "Подать заявку на регистрацию" nor a link "Отозвать" in this
  # region. The labels here deliberately match neither string.
  describe "the join-request inbox" do
    def render_for(user, team, requests)
      assign(:team, team)
      assign(:current_user, user)
      assign(:join_requests, requests)
      view.define_singleton_method(:current_user) { user }
      view.define_singleton_method(:logged_in?) { true }
      render
    end

    it "shows the captain each pending applicant, with accept and reject forms" do
      captain = create_user
      team = create_team(:captain => captain)
      applicant = create_user
      request = TeamJoinRequest.create!(:user => applicant, :team => team)

      render_for(captain.reload, team, [request])

      expect(rendered).to include(I18n.t("team_room.index.join_requests"))
      expect(rendered).to include(applicant.nickname)

      accept_tag = rendered[%r{<form[^>]*action="#{Regexp.escape(accept_join_request_path(request))}"[^>]*>}]
      expect(accept_tag).not_to be_nil
      expect(accept_tag).to include('method="post"')
      expect(rendered).to include(reject_join_request_path(request))
    end

    it "shows a plain member nothing of it" do
      captain = create_user
      team = create_team(:captain => captain)
      member = create_user
      team.members << member
      request = TeamJoinRequest.create!(:user => create_user, :team => team)

      render_for(member.reload, team, [request])

      expect(rendered).not_to include(I18n.t("team_room.index.join_requests"))
      expect(rendered).not_to include(accept_join_request_path(request))
    end

    it "says nothing when there are no pending requests" do
      captain = create_user
      team = create_team(:captain => captain)

      render_for(captain.reload, team, [])

      expect(rendered).not_to include(I18n.t("team_room.index.join_requests"))
    end
  end

  # The leave control is hidden exactly where TeamsController#leave refuses,
  # so it is never a promise that cannot be kept. Phase 4, S3/D3/D5.
  describe "the leave control" do
    def render_for(user, team)
      assign(:team, team)
      assign(:current_user, user)
      assign(:join_requests, [])
      view.define_singleton_method(:current_user) { user }
      view.define_singleton_method(:logged_in?) { true }
      render
    end

    it "is offered to a plain member, as a POSTing form" do
      captain = create_user
      team = create_team(:captain => captain)
      member = create_user
      team.members << member

      render_for(member.reload, team)

      # Matched in two steps so the assertion does not depend on Rails'
      # attribute ORDER -- button_to emits action before method.
      form_tag = rendered[%r{<form[^>]*action="#{Regexp.escape(leave_teams_path)}"[^>]*>}]
      expect(form_tag).not_to be_nil
      expect(form_tag).to include('method="post"')
    end

    # They must hand over first. The handover control is right above this one,
    # so hiding leave is a signpost rather than a dead end.
    it "is not offered to a captain who still has teammates" do
      captain = create_user
      team = create_team(:captain => captain)
      team.members << create_user

      render_for(captain.reload, team)

      expect(rendered).not_to include(leave_teams_path)
    end

    # D5: nobody to hand to, so leaving is allowed and takes the role along.
    it "is offered to a solo captain" do
      solo = create_user
      team = create_team(:captain => solo)

      render_for(solo.reload, team)

      expect(rendered).to include(leave_teams_path)
    end

    it "is not offered to anyone while the team is in a live race (leave)" do
      captain = create_user
      team = create_team(:captain => captain)
      member = create_user
      team.members << member
      create_game_passing(:team => team, :level => create_level)

      render_for(member.reload, team.reload)

      expect(rendered).not_to include(leave_teams_path)
    end
  end
end
