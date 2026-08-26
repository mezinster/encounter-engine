# -*- encoding : utf-8 -*-
require "rails_helper"

# A test admission granted by the author (or an operator) is the one grant in
# this app the recipient has no way of discovering: TestAdmissionsController
# #join is self-service -- the tester followed a token link and knows what they
# did -- but #create_team and #create_player admit somebody who never asked.
# Before these examples the only trace was a block appearing on their dashboard
# if they happened to look.
describe "test-admission notifications", type: :request do
  let(:author) { create_user }
  let(:game)   { create_game(:author => author, :is_draft => true, :name => "Ночной дозор") }
  let!(:level) { create_level(:game => game) }

  def sign_in(user)
    put login_path, :params => { :email => user.email, :password => "1234" }
  end

  # Raised from the delivery itself so MailDelivery's own rescue runs rather
  # than being stubbed away -- same idiom as spec/requests/mail_failure_spec.rb.
  def break_smtp!
    allow_any_instance_of(ActionMailer::MessageDelivery)
      .to receive(:deliver_now)
      .and_raise(Net::SMTPAuthenticationError.new("535 5.7.8 Username and Password not accepted"))
  end

  def recipients
    ActionMailer::Base.deliveries.flat_map(&:to)
  end

  before do
    sign_in(author)
    post start_test_game_path(game)
    game.reload
    ActionMailer::Base.deliveries.clear
  end

  describe "admitting one player" do
    it "tells that player they have been invited" do
      player = create_user

      expect {
        post test_admit_player_path(:game_id => game.id), :params => { :nickname => player.nickname }
      }.to change { ActionMailer::Base.deliveries.count }.by(1)

      expect(recipients).to eq([player.email])
    end

    it "names the game in the letter" do
      player = create_user
      post test_admit_player_path(:game_id => game.id), :params => { :nickname => player.nickname }

      expect(ActionMailer::Base.deliveries.last.subject).to include("Ночной дозор")
    end

    # The author plays a test run through may_start_passing?'s own exemption,
    # so create_player returns before writing anything. No grant, no letter.
    it "writes to nobody when the author names themselves" do
      expect {
        post test_admit_player_path(:game_id => game.id), :params => { :nickname => author.nickname }
      }.not_to change { ActionMailer::Base.deliveries.count }
    end

    it "writes to nobody when the player is already admitted" do
      player = create_user
      post test_admit_player_path(:game_id => game.id), :params => { :nickname => player.nickname }
      ActionMailer::Base.deliveries.clear

      expect {
        post test_admit_player_path(:game_id => game.id), :params => { :nickname => player.nickname }
      }.not_to change { ActionMailer::Base.deliveries.count }
    end
  end

  describe "admitting a team" do
    # "Captain plus all members": Team#adopt_captain already forces the captain
    # into members, so the union is a no-op today and .uniq is what keeps it
    # honest -- the captain must not get two copies of the same letter.
    it "writes once to every member, the captain included" do
      captain = create_user
      member  = create_user
      team    = create_team(:captain => captain, :members => [member])

      post test_admit_team_path(:game_id => game.id), :params => { :name => team.name }

      expect(recipients.sort).to eq([captain.email, member.email].sort)
    end

    it "names the team in the letter" do
      team = create_team(:captain => create_user)
      post test_admit_team_path(:game_id => game.id), :params => { :name => team.name }

      expect(ActionMailer::Base.deliveries.last.subject).to include(team.name)
    end

    it "writes to nobody when the named team does not exist" do
      expect {
        post test_admit_team_path(:game_id => game.id), :params => { :name => "Нет такой" }
      }.not_to change { ActionMailer::Base.deliveries.count }
    end
  end

  describe "revoking" do
    it "tells a solo tester their access is gone" do
      tester    = create_user
      admission = create_test_admission(:run => game.current_run,
                                        :team => create_team, :user => tester)

      expect {
        post revoke_test_admission_path(:game_id => game.id, :id => admission.id)
      }.to change { ActionMailer::Base.deliveries.count }.by(1)

      expect(recipients).to eq([tester.email])
    end

    # Every member, not just the captain -- the same recipient rule as the
    # admission letter. (An earlier version of this comment claimed the team
    # was destroyed by now and that the read order was therefore load-bearing.
    # It is not: revoke! destroys the team only for a solo admission. See the
    # controller.)
    it "tells every member of a revoked team" do
      captain   = create_user
      member    = create_user
      team      = create_team(:captain => captain, :members => [member])
      admission = create_test_admission(:run => game.current_run, :team => team)

      post revoke_test_admission_path(:game_id => game.id, :id => admission.id)

      expect(recipients.sort).to eq([captain.email, member.email].sort)
    end

    it "offers no play link, since the access is what was withdrawn" do
      tester    = create_user
      admission = create_test_admission(:run => game.current_run,
                                        :team => create_team, :user => tester)

      post revoke_test_admission_path(:game_id => game.id, :id => admission.id)

      expect(ActionMailer::Base.deliveries.last.body.encoded).not_to include("/play/")
    end
  end

  # #join is the self-service token link. The tester clicked it; telling them
  # what they just did is noise.
  describe "joining through the invite link" do
    it "sends nothing" do
      tester = create_user
      token  = game.current_run.test_token
      delete logout_path
      sign_in(tester)

      expect {
        post join_test_path(:game_id => game.id, :token => token)
      }.not_to change { ActionMailer::Base.deliveries.count }
    end
  end

  # The admission is the operation; the letter is not. An SMTP outage must not
  # cost the author the grant they just made.
  describe "when SMTP is down" do
    it "still admits the player" do
      break_smtp!
      player = create_user

      expect {
        post test_admit_player_path(:game_id => game.id), :params => { :nickname => player.nickname }
      }.to change { TestAdmission.count }.by(1)
    end

    it "warns the author that the letter did not go out" do
      break_smtp!
      player = create_user

      post test_admit_player_path(:game_id => game.id), :params => { :nickname => player.nickname }

      expect(flash[:alert]).to be_present
    end

    # &=, not &&=: one unreachable member must not stop the loop, and the
    # remaining members must still get theirs. Pinning the count proves the
    # loop ran to the end rather than aborting on the first failure.
    it "attempts every member of a team even when delivery keeps failing" do
      captain = create_user
      member  = create_user
      team    = create_team(:captain => captain, :members => [member])

      attempts = 0
      allow_any_instance_of(ActionMailer::MessageDelivery)
        .to receive(:deliver_now) do
          attempts += 1
          raise Net::SMTPAuthenticationError, "535 5.7.8 Username and Password not accepted"
        end

      post test_admit_team_path(:game_id => game.id), :params => { :name => team.name }

      expect(attempts).to eq(2)
      expect(TestAdmission.count).to eq(1)
    end
  end
end
