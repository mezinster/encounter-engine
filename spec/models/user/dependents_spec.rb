# -*- encoding : utf-8 -*-
require "rails_helper"

# User declared no dependent: option at all, and three tables reference it:
# invitations.for_user_id, team_join_requests.user_id and
# game_locale_preferences.user_id. Nothing could delete a user before phase 6,
# so nothing had noticed.
#
# The join-requests one is not cosmetic. The captain's inbox added in phase 5
# renders join_request.user.nickname, so a dangling row would 500 the team
# room for that captain -- a screen the deleted user has nothing to do with.
#
# Asserted per table rather than in aggregate, so a partial fix cannot pass.
RSpec.describe User, "dependent records" do
  it "takes its invitations with it" do
    captain = create_user
    team = create_team(:captain => captain)
    invitee = create_user
    invitation = create_invitation(:for => invitee, :from => team)

    invitee.destroy

    expect(Invitation.find_by(:id => invitation.id)).to be_nil
  end

  it "takes its join requests with it" do
    applicant = create_user
    request = TeamJoinRequest.create!(:user => applicant,
                                      :team => create_team(:captain => create_user))

    applicant.destroy

    expect(TeamJoinRequest.find_by(:id => request.id)).to be_nil
  end

  it "takes its game locale preferences with it" do
    user = create_user
    preference = GameLocalePreference.create!(:user => user, :game => create_game,
                                              :locale => "en")

    user.destroy

    expect(GameLocalePreference.find_by(:id => preference.id)).to be_nil
  end

  # The end-to-end consequence, rather than three separate row counts: the
  # screen that would actually break.
  it "leaves the captain's inbox renderable after an applicant is deleted" do
    captain = create_user
    team = create_team(:captain => captain)
    applicant = create_user
    TeamJoinRequest.create!(:user => applicant, :team => team)

    applicant.destroy

    expect(TeamJoinRequest.pending.to_team(team).map { |r| r.user&.nickname }).to eq([])
  end

  # Deliberately NOT dependent: destroy. Games are content other people
  # played, so deletion refuses a user who authored any -- see
  # Admin::UsersController#destroy.
  it "does not take authored games with it" do
    author = create_user
    game = create_game(:author => author)

    author.destroy

    expect(Game.find_by(:id => game.id)).not_to be_nil
  end
end
