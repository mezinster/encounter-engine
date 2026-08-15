require "rails_helper"

# start_test moves starts_at to now, which makes any future registration
# deadline violate deadline_is_before_game_start. The original fix for that was
# to blank the deadline -- but unlike starts_at, which is stashed in test_date
# and restored by finish_test, the deadline was simply destroyed. An author who
# rehearsed their game lost the cutoff they had set, permanently and silently.
#
# That is not cosmetic. shared/_game_entry_controls.html.erb:18 needs a
# NON-NIL deadline to report registration closed, so a wiped deadline means
# registration never closes -- teams keep applying up to kickoff, bounded only
# by max_team_number.
describe "a test run and the registration deadline", type: :request do
  let(:author)   { create_user }
  let(:deadline) { Time.parse("2099-01-01 12:00") }
  let(:game) do
    create_game(:author => author, :is_draft => true,
                :starts_at => "2099-02-01 15:00",
                :registration_deadline => deadline)
  end
  let!(:level) { create_level(:game => game) }

  def sign_in(user)
    put login_path, :params => { :email => user.email, :password => "1234" }
  end

  before { sign_in(author) }

  # Guards the guard. Every example below is vacuous if the test never starts,
  # and a start_test that fails its save redirects with an alert rather than
  # raising -- which reads exactly like success from any assertion about the
  # deadline alone. This example is why the first probe's apparent pass was
  # caught as a false one.
  it "still enters test mode" do
    post start_test_game_path(game)

    game.reload.is_testing.should be true
  end

  it "keeps the deadline through the test" do
    post start_test_game_path(game)

    game.reload.registration_deadline.to_i.should == deadline.to_i
  end

  it "still has it after the test finishes" do
    post start_test_game_path(game)
    post finish_test_game_path(game)

    game.reload.registration_deadline.to_i.should == deadline.to_i
  end

  # Compared against the value the record actually held, not a re-parsed
  # literal: create_game stores "2099-02-01 15:00" in the application's zone
  # while Time.parse in a spec reads the system's, and the two differ by the
  # local offset.
  it "restores the start date as before" do
    original = game.reload.starts_at

    post start_test_game_path(game)
    post finish_test_game_path(game)

    game.reload.starts_at.to_i.should == original.to_i
  end

  it "no longer tells the author no deadline is set" do
    post start_test_game_path(game)

    get game_path(game)

    response.body.should_not include("Крайний срок регистрации ещё не назначен")
  end

  # The consequence that makes this a data-loss bug rather than a wrong label.
  it "leaves registration able to close after the test" do
    post start_test_game_path(game)
    post finish_test_game_path(game)

    game.reload.registration_deadline.should_not be_nil
  end

  # A game with no deadline is a real, existing state -- GameRun's own comment
  # records that production game 3 has none -- so the change must not invent one.
  it "leaves a game that never had a deadline alone" do
    plain = create_game(:author => author, :is_draft => true,
                        :starts_at => "2099-02-01 15:00")
    create_level(:game => plain)

    post start_test_game_path(plain)
    plain.reload.is_testing.should be true

    post finish_test_game_path(plain)
    plain.reload.registration_deadline.should be_nil
  end
end
