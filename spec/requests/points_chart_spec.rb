require "rails_helper"

describe "the points chart", type: :request do
  let(:viewer) { create_user }

  def sign_in(user)
    put login_path, :params => { :email => user.email, :password => "1234" }
  end

  def scoring_game
    game  = create_game(:points_enabled => true, :level_completion_points => 10,
                        :game_completion_points => 50)
    level = create_level(:game => game, :position => 1)
    [ game, level ]
  end

  it "shows a team's balance" do
    game, level = scoring_game
    passing = create_game_passing(:game => game, :level => level)
    PointTransaction.award!(:passing => passing, :reason => "level_completed",
                            :level => level, :amount => 10)
    sign_in(viewer)

    get teams_path

    expect(response).to have_http_status(:ok)
    expect(response.body).to include(passing.team.name)
    expect(response.body).to include("10")
  end

  # Asserts on the rendered "0" itself, scoped to this team's own <tr> --
  # not merely that the page contains the character "0" somewhere (the page
  # legitimately does, for other reasons) and not merely that the team isn't
  # dropped from the list (guaranteed independently: @teams comes from the
  # Team relation, never from a join against the point/passing aggregates).
  # Mutation-tested: dropping the view's `.fetch(team.id, 0)` defaults (so a
  # team absent from @started/@finished renders a blank cell instead of "0")
  # turns this red; seeing that failure, not just believing it, is what this
  # example is worth. See task-4-report.md, Fix round 1, for the transcript.
  it "shows a team with no transactions at zero rather than omitting it" do
    team = create_team(:captain => create_user)
    sign_in(viewer)

    get teams_path

    # The row for this team, bounded so the scan can't cross into a
    # neighbouring <tr> before finding the name.
    row = response.body[/<tr>(?:(?!<\/tr>).)*?#{Regexp.escape(team.name)}.*?<\/tr>/m]
    expect(row).not_to be_nil

    # Five consecutive zero-valued cells: games started, games finished,
    # points earned, points deducted, balance -- the five columns this task
    # added. (The preceding "members" cell reads "1", from the captain's
    # automatic membership, so it can't be mistaken for one of these.)
    zero_cell = %q{<td data-label="[^"]*">0</td>}
    expect(row).to match(Regexp.new(([ zero_cell ] * 5).join("\\s*"), Regexp::MULTILINE))
  end

  # An earlier tie-break example in this suite compared two randomly-named
  # fixtures on an all-zero chart and could not fail: the base query is
  # already `Team.order(:name)`, so when EVERY team ties on balance, Ruby's
  # `sort_by` (empirically, in this Ruby) leaves an already name-sorted
  # array untouched even with the explicit name key deleted from the sort --
  # the SQL order alone produces the "right" answer by coincidence, whether
  # or not the controller's tie-break exists.
  #
  # That coincidence only holds when the WHOLE array is tied. It breaks once
  # the tie-break's two candidates are surrounded by teams on distinct,
  # varied balances: sort_by then genuinely reorders a tied subgroup instead
  # of leaving it alone (verified directly, not assumed -- see task-4-report,
  # Fix round 1). So this example surrounds the two candidates with 24 noise
  # teams on distinct nonzero balances, and creates the candidates in
  # reverse-of-alphabetical order so nothing here can be rescued by
  # insertion order either. It does not lean on `.order(:name)` to save it:
  # deleting the explicit `t.name.to_s` key from the controller's sort_by
  # flips this example red (confirmed by mutating the tracked controller
  # file directly, not a stand-in).
  it "breaks ties on name even when other teams sort by balance around them" do
    game  = create_game(:points_enabled => true, :level_completion_points => 10,
                        :game_completion_points => 50)
    level = create_level(:game => game, :position => 1)

    ("C".."Z").to_a.each_with_index do |letter, i|
      noise = create_team(:captain => create_user)
      noise.update!(:name => letter * 3)
      passing = create_game_passing(:game => game, :level => level, :team => noise)
      PointTransaction.award!(:passing => passing, :reason => "level_completed",
                              :level => level, :amount => 10 + i)
    end

    # create_team IGNORES a :name option -- it always generates "Team#<random>"
    # -- so the names are set afterwards. Created in reverse-of-alphabetical
    # order: "Bbb" first, "Aaa" second.
    b = create_team(:captain => create_user); b.update!(:name => "Bbb")
    a = create_team(:captain => create_user); a.update!(:name => "Aaa")
    sign_in(viewer)

    get teams_path

    expect(response.body.index(a.name)).to be < response.body.index(b.name)
  end

  it "sorts by balance, highest first" do
    game, level = scoring_game
    poor = create_game_passing(:game => game, :level => level)
    rich = create_game_passing(:game => game, :level => level)
    PointTransaction.award!(:passing => poor, :reason => "level_completed",
                            :level => level, :amount => 10)
    PointTransaction.award!(:passing => rich, :reason => "level_completed",
                            :level => level, :amount => 90)
    sign_in(viewer)

    get teams_path

    expect(response.body.index(rich.team.name)).to be < response.body.index(poor.team.name)
  end

  it "counts deductions against the balance" do
    game, level = scoring_game
    passing = create_game_passing(:game => game, :level => level)
    PointTransaction.award!(:passing => passing, :reason => "level_completed",
                            :level => level, :amount => 10)
    PointTransaction.award!(:passing => passing, :reason => "game_completed",
                            :level => nil, :amount => -4)
    sign_in(viewer)

    get teams_path

    expect(response.body).to include("6")
  end

  # The row for one team, bounded so the scan cannot cross into a neighbour
  # before finding the name. Same shape as the zero-balance example above.
  def row_for(team)
    response.body[/<tr>(?:(?!<\/tr>).)*?#{Regexp.escape(team.name)}.*?<\/tr>/m]
  end

  def cells(row)
    row.to_s.scan(/data-label="[^"]*">([^<]*)</).flatten.map(&:strip)
  end

  # The design's section 7 asks for a team with a mixture of finished and
  # ABANDONED runs, and neither request spec had one -- which is why the two
  # screens' disagreement about "finished" went unnoticed. exit! stamps
  # finished_at as well as status "exited", so a chart reading finished_at
  # alone would say 1 here.
  it "counts an abandoned run as started but never completed" do
    game, level = scoring_game
    passing = create_game_passing(:game => game, :level => level)
    PointTransaction.award!(:passing => passing, :reason => "level_completed",
                            :level => level, :amount => 10)
    passing.exit!
    sign_in(viewer)

    get teams_path

    # No completion award was written, and none is owed: P4.
    expect(PointTransaction.where(:reason => "game_completed")).to be_empty
    # name, captain, members, started, finished, earned, deducted, balance
    expect(cells(row_for(passing.team))[3, 5]).to eq(%w[1 0 10 0 10])
  end

  it "still counts a genuinely finished run as completed" do
    game, level = scoring_game
    passing = create_game_passing(:game => game, :level => level)
    passing.update!(:finished_at => Time.now)
    sign_in(viewer)

    get teams_path

    expect(cells(row_for(passing.team))[3, 2]).to eq(%w[1 1])
  end

  # A rehearsal writes no ledger row (GamePassing#award_points_for returns
  # early on a testing run), so counting its passings here reported a team
  # that has never played anything real as "1 started, 1 finished, 0 points".
  it "does not count a run that was only a rehearsal" do
    game, level = scoring_game
    game.current_run.update_column(:is_testing, true)
    passing = create_game_passing(:game => game, :level => level)
    passing.update!(:finished_at => Time.now)
    sign_in(viewer)

    get teams_path

    expect(cells(row_for(passing.team))[3, 5]).to eq(%w[0 0 0 0 0])
  end

  # game_run is :optional and nil means an ORDINARY run, so the testing filter
  # must not swallow a run-less passing: `NOT IN (...)` is NULL, and so false,
  # for a NULL column under SQL's three-valued logic.
  #
  # The rehearsal below is what gives this example teeth. `NULL IN (empty
  # set)` is FALSE rather than NULL, so with no testing run in the database a
  # bare NOT IN keeps the row anyway and the example cannot fail. Verified: it
  # was written without these two lines and stayed green under the mutation.
  it "counts a passing that belongs to no run at all" do
    rehearsed, rehearsed_level = scoring_game
    create_game_passing(:game => rehearsed, :level => rehearsed_level)
    rehearsed.current_run.update_column(:is_testing, true)

    game, level = scoring_game
    passing = create_game_passing(:game => game, :level => level)
    passing.update!(:game_run => nil, :finished_at => Time.now)
    sign_in(viewer)

    get teams_path

    expect(cells(row_for(passing.team))[3, 2]).to eq(%w[1 1])
  end

  # The chart's figures must be grouped queries. This programme has introduced
  # the same N+1 three times; the existing slope guard in teams_index_spec.rb
  # is what catches a fourth.
  it "keeps the query count flat as the number of teams grows" do
    game, level = scoring_game
    sign_in(viewer)
    2.times { create_point_transaction(:passing => create_game_passing(:game => game, :level => level)) }
    small = count_queries { get teams_path }

    6.times { create_point_transaction(:passing => create_game_passing(:game => game, :level => level)) }
    large = count_queries { get teams_path }

    expect(large).to eq(small)
  end
end
