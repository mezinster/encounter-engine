# -*- encoding : utf-8 -*-
require "rails_helper"

# The three outcomes a passing can be in, as the admin overview reports them.
#
# The overview used to ask only `where(finished_at: nil)` for "in progress",
# and that is wrong in a way an operator sees on the page: GamePassing#end!
# sets status "ended" WITHOUT stamping finished_at, so every team the author
# ended by pressing "ЗАВЕРШИТЬ ИГРУ" was still being reported as playing --
# on an instance whose only game was finished and where nothing was running.
#
# The subtlety that shapes these three scopes is in GamesController#end_game:
#
#   @game.current_run.passings.each(&:end!)
#
# every passing of the run, and #end! skips only exited ones. So a team that
# genuinely crossed the finish line ALSO ends up with status "ended" the
# moment the author closes the game. "ended" therefore cannot mean "did not
# finish" on its own -- finished_at is what says whether the course was
# completed, and exited? is what separates crossing the line from walking off
# it. That is the same pair GamePassingsHelper#full_log_visible? and
# LogsController use to decide who genuinely finished.
describe "GamePassing outcome scopes" do
  let(:game)  { create_game }
  let(:level) { create_level(:game => game) }

  def passing(attrs = {})
    create_game_passing({ :level => level, :game_run => game.current_run }.merge(attrs))
  end

  # Crossed the finish line. Stays completed even after the author closes the
  # game and stamps "ended" over the top of it.
  it "counts a team that finished, before and after the author ends the game" do
    finished = passing(:finished_at => Time.now)

    expect(GamePassing.completed).to include(finished)

    finished.end!

    expect(GamePassing.completed).to include(finished.reload)
    expect(GamePassing.interrupted).not_to include(finished)
    expect(GamePassing.in_progress).not_to include(finished)
  end

  it "counts a team the author ended mid-course as interrupted, not as playing" do
    mid_course = passing
    mid_course.end!

    expect(GamePassing.interrupted).to include(mid_course.reload)
    expect(GamePassing.in_progress).not_to include(mid_course)
    expect(GamePassing.completed).not_to include(mid_course)
  end

  # exit! stamps finished_at as well as the status, so finished_at alone would
  # file a team that walked off the course under "completed".
  it "counts a team that walked off the course as interrupted" do
    quitter = passing
    quitter.exit!

    expect(GamePassing.interrupted).to include(quitter.reload)
    expect(GamePassing.completed).not_to include(quitter)
    expect(GamePassing.in_progress).not_to include(quitter)
  end

  # status is nullable and nil is the ordinary in-progress value, so a plain
  # `where.not(status: [...])` generates NOT IN, which under SQL's
  # three-valued logic is NULL -- and therefore false -- for every nil-status
  # row. That would zero out the common case, which is the whole population of
  # a running game.
  it "counts an ordinary nil-status team as playing" do
    playing = passing

    expect(GamePassing.in_progress).to include(playing)
    expect(GamePassing.completed).not_to include(playing)
    expect(GamePassing.interrupted).not_to include(playing)
  end

  # The property the overview actually depends on, and the one a fourth status
  # would break silently: three tiles that add up to what is there.
  it "partitions every passing between exactly the three of them" do
    finished_then_ended = passing(:finished_at => Time.now)
    finished_then_ended.end!
    passing(:finished_at => Time.now)
    passing.end!
    passing.exit!
    passing

    total = GamePassing.count
    sum   = GamePassing.completed.count +
            GamePassing.interrupted.count +
            GamePassing.in_progress.count

    expect(total).to eq(5)
    expect(sum).to eq(total),
      "completed #{GamePassing.completed.count}, " \
      "interrupted #{GamePassing.interrupted.count}, " \
      "in_progress #{GamePassing.in_progress.count} -- " \
      "these three must cover every row exactly once"
  end

  # #completed? and #interrupted? are the Ruby twins the public team page
  # reads (it holds a loaded row, not a relation). They are written out by
  # hand rather than delegating to the scopes, so this is what stops the two
  # forms drifting: every row above is fed to both, and they must agree.
  it "agrees with its own scope, row for row" do
    finished_then_ended = passing(:finished_at => Time.now)
    finished_then_ended.end!
    finished  = passing(:finished_at => Time.now)
    ended     = passing.tap(&:end!)
    quitter   = passing.tap(&:exit!)
    playing   = passing

    [ finished_then_ended, finished, ended, quitter, playing ].each do |row|
      row.reload
      expect(row.completed?).to eq(GamePassing.completed.exists?(row.id)),
        "completed? disagrees with the scope for status=#{row.status.inspect} " \
        "finished_at=#{row.finished_at.inspect}"
      expect(row.interrupted?).to eq(GamePassing.interrupted.exists?(row.id)),
        "interrupted? disagrees with the scope for status=#{row.status.inspect} " \
        "finished_at=#{row.finished_at.inspect}"
    end
  end

  # --- not_testing --------------------------------------------------------
  #
  # The counterpart of #award_points_for's testing guard, for the chart's
  # games-started/games-finished columns.
  describe "not_testing" do
    it "drops a passing on a run that is being test-run" do
      rehearsal = passing
      game.current_run.update_column(:is_testing, true)

      expect(GamePassing.not_testing).not_to include(rehearsal)
    end

    it "keeps a passing on an ordinary run" do
      real = passing

      expect(GamePassing.not_testing).to include(real)
    end

    # game_run is :optional and nil means an ORDINARY run. A bare
    # `where.not(:game_run_id => testing)` generates NOT IN, which is NULL --
    # and so false -- for a NULL column, silently dropping every one of these.
    #
    # A testing run must EXIST for this to be able to fail, and that is not a
    # detail: `NULL IN (empty set)` is FALSE, not NULL, so with no testing run
    # anywhere the bare NOT IN keeps the row and the example proves nothing.
    # Written without the second game first, and it stayed green under exactly
    # the mutation it exists to catch.
    it "keeps a passing that belongs to no run at all" do
      other = create_game
      create_level(:game => other)
      other.current_run.update_column(:is_testing, true)

      runless = passing
      runless.update!(:game_run => nil)

      expect(GameRun.where(:is_testing => true)).not_to be_empty
      expect(GamePassing.not_testing).to include(runless)
    end

    it "composes with completed without losing either condition" do
      done = passing(:finished_at => Time.now)
      quit = passing(:team => create_team).tap(&:exit!)

      expect(GamePassing.not_testing.completed).to include(done)
      expect(GamePassing.not_testing.completed).not_to include(quit)

      game.current_run.update_column(:is_testing, true)

      expect(GamePassing.not_testing.completed).not_to include(done)
    end
  end
end
