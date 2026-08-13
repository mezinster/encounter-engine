require "rails_helper"

describe GameFileAccess do
  before(:each) do
    @author = create_user
    @game   = create_game(:author => @author)
    @file   = GameFileUpload.new(@game, fixture_upload("photo.jpg"), @author).call
  end

  it "permits the game's author" do
    expect(GameFileAccess.new(@author, @file).permitted?).to be true
  end

  it "permits a superadmin who is not the author" do
    admin = create_user
    admin.update_column(:is_superadmin, true)

    expect(GameFileAccess.new(admin, @file).permitted?).to be true
  end

  it "refuses the author of a DIFFERENT game" do
    # Not "some logged-in user" -- an author specifically. authorship is
    # per game, and a policy that checked `user.author_of_anything?` would
    # pass this and hand every author every other author's library.
    other = create_user
    create_game(:author => other)

    expect(GameFileAccess.new(other, @file).permitted?).to be false
  end

  it "refuses an anonymous requester" do
    expect(GameFileAccess.new(nil, @file).permitted?).to be false
  end

  it "REFUSES a team whose only passing is in another game, even when that passing is further along" do
    # Mutation guard: dropping the game scope from passing_for_game entirely
    # still passes the pre-existing "refuses a team playing a different
    # game" example below, because that example's other-game passing sits
    # on POSITION 1 and the attached file sits on position 2 -- so the
    # POSITION comparison denies it, not the game scope. Putting the other
    # game's passing further along than the attachment removes that
    # coincidence: only an actual game-scoped lookup can refuse this.
    other_game = create_game(:author => create_user)
    create_level(:game => other_game)
    create_level(:game => other_game)
    o3 = create_level(:game => other_game)
    user = create_user
    team = create_team(:members => [ user ])
    user.reload
    create_game_passing(:level => o3, :team => team) # position 3 there
    l1 = create_level(:game => @game)
    FileAttachment.create!(:game_file => @file, :attachable => l1) # position 1 here

    expect(GameFileAccess.new(user, @file).permitted?).to be false
  end

  it "REFUSES a passing that this game's run hands back but that belongs to another game" do
    # Corruption-only: a passing reached through game.current_run should
    # already be this game's. The check exists because both Critical holes
    # this file has shipped were the same shape -- a lookup that LOOKED
    # correctly scoped handing back a passing from somewhere else, silently.
    # update_column to write the state no validated path can produce.
    user = create_user
    team = create_team(:members => [ user ])
    user.reload
    l1 = create_level(:game => @game)
    passing = create_game_passing(:level => l1, :team => team)
    FileAttachment.create!(:game_file => @file, :attachable => l1)

    # Sanity: this is permitted before the row is corrupted, so the example
    # cannot pass merely because something else refuses it.
    expect(GameFileAccess.new(user, @file).permitted?).to be true

    passing.update_column(:game_id, create_game(:author => create_user).id)

    expect(GameFileAccess.new(user, @file).permitted?).to be false
  end

  describe "a playing team" do
    before(:each) do
      @team_user = create_user
      # :members, not :user -- create_team takes :captain and :members only, and
      # User belongs_to :team, so the association is set from the team side.
      @team = create_team(:members => [ @team_user ])
      @team_user.reload
      @l1 = create_level(:game => @game, :name => "L1")
      @l2 = create_level(:game => @game, :name => "L2")
      @l3 = create_level(:game => @game, :name => "L3")
      # :level, not :game + :current_level -- create_game_passing derives the
      # game from the level and defaults the run. Passing :game explicitly still
      # calls create_level for the default and leaves a stray level behind.
      @passing = create_game_passing(:level => @l2, :team => @team)
    end

    def attach!(attachable, locale = nil)
      FileAttachment.create!(:game_file => @file, :attachable => attachable, :locale => locale)
    end

    it "permits a file on the level the team is currently on" do
      attach!(@l2)
      expect(GameFileAccess.new(@team_user, @file).permitted?).to be true
    end

    it "permits a file on a level the team has already passed" do
      attach!(@l1)
      expect(GameFileAccess.new(@team_user, @file).permitted?).to be true
    end

    it "REFUSES a file on a level the team has not reached" do
      # The row that matters. A level's photograph is often the puzzle; serving
      # it early hands the next answer to anyone who can guess an id.
      attach!(@l3)
      expect(GameFileAccess.new(@team_user, @file).permitted?).to be false
    end

    it "permits a file on a hint that has already fired" do
      # :delay is in SECONDS, not minutes -- Hint#ready_to_show? compares it
      # directly against `now - current_level_entered_at`.
      hint = create_hint(:level => @l2, :delay => 0)
      @passing.update!(:current_level_entered_at => 1.hour.ago)
      attach!(hint)

      expect(GameFileAccess.new(@team_user, @file).permitted?).to be true
    end

    it "permits a file on a hint that never fired, on a level the team has already passed" do
      # Design §4: the passed-level exception covers hints too. A hint that
      # never fired on a level the team has already left behind cannot tell
      # them anything they still need -- they solved the level without it --
      # so it is visible exactly like the level's own file is.
      hint = create_hint(:level => @l1, :delay => 1800)
      @passing.update!(:current_level_entered_at => Time.now) # would not have fired if still current
      attach!(hint)

      expect(GameFileAccess.new(@team_user, @file).permitted?).to be true
    end

    it "REFUSES a file on a hint that has NOT fired yet" do
      hint = create_hint(:level => @l2, :delay => 1800)
      @passing.update!(:current_level_entered_at => Time.now)
      attach!(hint)

      expect(GameFileAccess.new(@team_user, @file).permitted?).to be false
    end

    it "permits every level once the passing has finished" do
      # current_level is nil at this point -- see the domain note above. Without
      # an explicit branch the position comparison raises NoMethodError and the
      # results screen 500s for every team that completed the game.
      attach!(@l3)
      @passing.update!(:current_level => nil, :finished_at => Time.now)

      expect(GameFileAccess.new(@team_user, @file).permitted?).to be true
    end

    it "permits when ANY of several attachments is visible" do
      attach!(@l1)
      attach!(@l3)

      expect(GameFileAccess.new(@team_user, @file).permitted?).to be true
    end

    it "REFUSES a file attached to nothing" do
      expect(GameFileAccess.new(@team_user, @file).permitted?).to be false
    end

    it "REFUSES a team playing a different game" do
      # A FRESH team, not @team: @team already has a passing on @game (from
      # this describe block's own before(:each), current level @l2) and
      # attaching to @l2 there would legitimately be visible -- that would
      # test nothing about game-scoping. This team's only passing is on
      # other_game, so it must be refused for a file that lives on @game.
      other_game = create_game(:author => create_user)
      other_level = create_level(:game => other_game)
      other_team_user = create_user
      other_team = create_team(:members => [ other_team_user ])
      other_team_user.reload
      create_game_passing(:level => other_level, :team => other_team)
      attach!(@l2)

      # The team's passing in the OTHER game must not authorise a file in THIS
      # one. Resolve the passing by game, never "the user's most recent".
      expect(GameFileAccess.new(other_team_user, @file).permitted?).to be false
    end

    describe "a team with a passing in more than one run of the same game" do
      before(:each) do
        # @passing (built by the outer before(:each)) is this team's passing
        # in run 1, current level @l2. Finish it, as a genuinely completed
        # run 1 would be -- then open run 2 and give the team a fresh,
        # in-progress passing there, back on @l1.
        @passing.update!(:current_level => nil, :finished_at => Time.now)
        @run2 = create_next_run(@game)
        @passing2 = create_game_passing(:level => @l1, :team => @team, :game_run => @run2)
      end

      it "REFUSES a file on a level the team has not reached in the LIVE run, despite a finished passing in an earlier run" do
        # The bug: GamePassing.find_by(:game_id, :team_id) is unordered and
        # can return run 1's row, which is `finished?` -- so every level in
        # the game reads as visible, including one the run-2 passing has
        # nowhere near reached.
        attach!(@l3)

        file = GameFile.find(@file.id) # fresh object graph -- no association caches from setup
        expect(GameFileAccess.new(@team_user, file).permitted?).to be false
      end

      it "permits a file on the team's CURRENT level in the LIVE run, despite a finished passing in an earlier run" do
        # The other half of the same bug: if the game-scoped lookup instead
        # happens to return run 1's finished row, a file on run 2's own
        # current level would be wrongly refused (finished? is true, but
        # the level position is compared against run 1's stale current
        # level, which is nil).
        attach!(@l1)

        file = GameFile.find(@file.id)
        expect(GameFileAccess.new(@team_user, file).permitted?).to be true
      end
    end

    it "REFUSES a file beyond the current level for a team that EXITED, even though exit! sets finished_at" do
      # GamePassing#exit! stamps finished_at AND status "exited" -- a naive
      # `finished?` check reads a team that walked off the course as one
      # that completed it, unlocking every level's file. This is the same
      # threat LogsController#ensure_full_log_access guards against (see the
      # comment there) and the reason GamePassing's own `completed` scope
      # excludes exited rows.
      attach!(@l3)
      @passing.exit!

      expect(GameFileAccess.new(@team_user, @file).permitted?).to be false
    end

    it "still permits every level for a team that GENUINELY finished (guard against over-correcting the exit! fix)" do
      attach!(@l3)
      @passing.update!(:current_level => nil, :finished_at => Time.now)

      expect(GameFileAccess.new(@team_user, @file).permitted?).to be true
    end

    it "REFUSES an attachment whose attachable is a type neither Level nor Hint recognises (fail-closed else branch)" do
      # Mutation guard: visible_to?'s `else false` is the only thing standing
      # between an unrecognised attachable type and a permit. Bypass
      # FileAttachment's own validations to build the row directly, since
      # nothing in normal use can produce one.
      attachment = FileAttachment.new(:game_file => @file, :attachable => @team)
      attachment.save(:validate => false)

      expect(GameFileAccess.new(@team_user, @file).permitted?).to be false
    end

    it "REFUSES a file attachment whose Level belongs to a DIFFERENT game than the file, even when the position lines up" do
      # Mutation guard: dropping `level.game_id == game.id` from
      # level_visible? still refuses via the position comparison IF the
      # foreign level's position is past the team's current one -- so the
      # foreign level here is given position 1, same as @l1, which is <=
      # the team's current level (@l2, position 2) and would wrongly permit
      # without the game_id check. FileAttachment's own
      # file_belongs_to_the_same_game validator blocks this row in normal
      # use, so it is built past validation, as a defence-in-depth guard.
      other_game = create_game(:author => create_user)
      foreign_level = create_level(:game => other_game) # position 1

      attachment = FileAttachment.new(:game_file => @file, :attachable => foreign_level)
      attachment.save(:validate => false)

      expect(GameFileAccess.new(@team_user, @file).permitted?).to be false
    end

    it "REFUSES rather than raises when current_level_entered_at is nil" do
      # Pre-existing model behaviour: Hint#ready_to_show? does
      # `now - current_level_entered_at`, which raises TypeError on nil
      # rather than returning false. Left unguarded, this route's contract
      # ("everything not permitted is a 404") breaks for exactly this
      # passing state, handing an id-enumerator a distinguishable 500.
      hint = create_hint(:level => @l2, :delay => 0)
      @passing.update_column(:current_level_entered_at, nil)
      attach!(hint)

      expect { GameFileAccess.new(@team_user, @file).permitted? }.not_to raise_error
      expect(GameFileAccess.new(@team_user, @file).permitted?).to be false
    end
  end
end
