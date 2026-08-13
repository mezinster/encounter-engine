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
  end
end
