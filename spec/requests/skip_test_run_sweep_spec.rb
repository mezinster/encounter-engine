require "rails_helper"

# D2 is the first thing that writes ledger rows into a testing run ON PURPOSE
# (see the spec, S7), so it is D2 that has to prove the sweep D1 shipped still
# collects everything. Without this, a skipped level during a test would leave
# rows behind and Team#deletable? -- which requires point_transactions.empty?
# -- would refuse the disposable team forever, exactly the bug D1's whole-branch
# review found and fixed.
describe "finishing a test run that contained a skip", type: :request do
  def sign_in(user)
    put login_path, :params => { :email => user.email, :password => "1234" }
  end

  it "leaves no ledger rows behind" do
    author  = create_user
    captain = create_user
    team    = create_team(:captain => captain)
    game    = create_game(:author => author, :max_skips => 2, :skip_points_fine => 25)
    one     = create_level(:game => game, :position => 1)
    create_level(:game => game, :position => 2)

    sign_in(author)
    post start_test_game_path(game)
    game.reload

    passing = create_game_passing(:game => game, :game_run => game.current_run,
                                  :level => one, :team => team)

    passing.skip_level!(captain)
    expect(PointTransaction.where(:game_passing_id => passing.id).count).to eq(1)

    post finish_test_game_path(game)

    expect(PointTransaction.where(:game_passing_id => passing.id).count).to eq(0)
  end
end
