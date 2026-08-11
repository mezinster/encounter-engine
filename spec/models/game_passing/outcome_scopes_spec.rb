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
end
