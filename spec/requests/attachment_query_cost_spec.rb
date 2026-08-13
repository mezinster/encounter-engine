require "rails_helper"

# Task 3 review finding (Important 3): the play screen used to cost ~10
# queries for every additional attached file (game_passings_controller.rb's
# original preload only nested :game_file => { :game => :runs }, leaving
# GameFile#existing_web_variant's blob/variant-record reads unpreloaded).
# preloaded_level now also nests
# :game_file => { :file_attachment => { :blob => { :variant_records =>
# { :image_attachment => :blob } } } } -- see that method's comment for the
# full chain and why each link is needed -- which measured at 10 files on
# one level: 103 -> 68 queries (11-file page: 153 -> 114).
#
# Some of the remaining per-file cost is NOT avoidable from this task's
# files: GameFileAccess#permitted? and GameFile#existing_web_variant both
# re-query on every call for reasons their own class comments document
# (.includes/.find_by on an association discards whatever was preloaded).
# So this is a SLOPE guard, not a magic total -- it measures the marginal
# cost of going from one attached file to ten and asserts it stays well
# under the pre-fix ~10/file, so dropping the preload (or reintroducing the
# per-hint N+1 this branch already fixed once, see
# spec/requests/translated_level_spec.rb) fails the build instead of
# quietly regressing every reload of this page.
describe "attachment strip query cost on the play screen", type: :request do
  SMALL_FILE_COUNT = 1
  LARGE_FILE_COUNT = 10
  # Measured today: ~4 queries per additional file. The pre-Important-3 cost
  # was ~8/file (and pre-Task-3-preload, ~10/file) -- this cap is set well
  # above the current measurement and well below either regression, so it
  # catches a real slope regression without pinning an exact number that
  # would need updating every time an unrelated column is added.
  MAX_MARGINAL_QUERIES_PER_FILE = 6

  def sign_in(user)
    put login_path, :params => { :email => user.email, :password => "1234" }
  end

  def build_level_with_files(n)
    author = create_user
    game = create_game(:author => author)
    set_game_schedule!(game, :starts_at => 1.hour.ago)
    level = create_level(:game => game)

    n.times { GameFileUpload.new(game, fixture_upload("photo.jpg"), author).call }
    level.replace_attached_files(GameFile.of_game(game).pluck(:id), nil)

    player = create_user
    team = create_team(:captain => player)
    create_game_entry(:game => game, :team => team)
    create_game_passing(:level => level, :team => team)

    [ game, player ]
  end

  def queries_for(file_count)
    game, player = build_level_with_files(file_count)
    sign_in(player)

    count_queries { get show_current_level_path(:game_id => game.id) }
  end

  it "keeps the marginal query cost per attached file well under the pre-fix rate" do
    small_count = queries_for(SMALL_FILE_COUNT)
    large_count = queries_for(LARGE_FILE_COUNT)

    marginal_per_file = (large_count - small_count).to_f / (LARGE_FILE_COUNT - SMALL_FILE_COUNT)

    expect(marginal_per_file).to be <= MAX_MARGINAL_QUERIES_PER_FILE
  end
end

# Task 4 review finding (Important 3): the guard above only covers
# show_current_level. Nothing guarded /play/:game_id/tip -- the ONE route
# every racing team's browser actually polls, repeatedly, for the lifetime
# of a level -- and the reviewer confirmed the gap is real: reverting
# preloaded_level_for_tip's attachment preload (game_passings_controller.rb)
# costs 23 extra queries at 5 attachments on a fired hint, and no test
# noticed.
#
# Measured with a single fired hint carrying N attached files: 1 file = 31
# queries, 5 = 63, 10 = 103 -- a flat ~8 queries per additional attachment,
# WITH the preload in place. Reverting the preload's nested
# :file_attachments => { :game_file => [...] } (leaving only
# :hints => :content_translations) changes that to 1 = 30, 5 = 86, 10 = 156
# -- ~14 queries per additional attachment.
#
# ~8/file, not the ~4/file show_current_level reaches post-Important-3, is
# the CORRECT baseline to guard here, not a laxer stand-in for it: this
# route reconstructs GameFileAccess once per file the same way
# show_current_level does, and per that class's own comments
# (game_file_access.rb), permitted? and existing_web_variant both re-query
# on every call regardless of what the caller preloaded -- refactoring that
# is explicitly out of scope for this round (see GameFileAccess's own class
# comment; it is accepted, not forgotten). So, like the guard above, this is
# a SLOPE guard, not a magic total that would need updating for an unrelated
# column -- the cap below sits comfortably above the current ~8/file and
# comfortably below the ~14/file measured with the preload reverted, which is
# the rate this route pays without it.
describe "attachment query cost on the live hint poller (/tip)", type: :request do
  TIP_SMALL_FILE_COUNT = 1
  TIP_LARGE_FILE_COUNT = 10
  # Measured today: ~8 queries per additional attachment (see file comment
  # above for the full 1/5/10 series). Reverting the preload measured ~14/file
  # -- this cap sits between the two, so it passes at the current rate and
  # fails if the preload this depends on is ever dropped.
  TIP_MAX_MARGINAL_QUERIES_PER_FILE = 10

  def sign_in(user)
    put login_path, :params => { :email => user.email, :password => "1234" }
  end

  # A single hint that fires immediately (delay: 0), carrying N files --
  # hint_attachments_json only ever serialises hints_to_show.last (see that
  # method's comment), so this is the shape that actually reaches the poller,
  # not a level-attached strip (which /tip never re-sends -- that already
  # reached the page at load time).
  def build_hint_with_files(n)
    author = create_user
    game = create_game(:author => author)
    set_game_schedule!(game, :starts_at => 1.hour.ago)
    level = create_level(:game => game)
    hint = create_hint(:level => level, :delay => 0, :text => "hint text")

    n.times { GameFileUpload.new(game, fixture_upload("photo.jpg"), author).call }
    hint.replace_attached_files(GameFile.of_game(game).pluck(:id), nil)

    player = create_user
    team = create_team(:captain => player)
    create_game_entry(:game => game, :team => team)
    create_game_passing(:level => level, :team => team)

    [ game, player ]
  end

  def queries_for(file_count)
    game, player = build_hint_with_files(file_count)
    sign_in(player)

    count_queries { get get_current_level_tip_path(:game_id => game.id) }
  end

  it "keeps the marginal query cost per attachment well under the no-preload rate" do
    small_count = queries_for(TIP_SMALL_FILE_COUNT)
    large_count = queries_for(TIP_LARGE_FILE_COUNT)

    marginal_per_file = (large_count - small_count).to_f / (TIP_LARGE_FILE_COUNT - TIP_SMALL_FILE_COUNT)

    expect(marginal_per_file).to be <= TIP_MAX_MARGINAL_QUERIES_PER_FILE
  end
end
