require "rails_helper"

describe TestAdmission do
  let(:game) { create_game }
  let(:run)  { game.current_run }

  before { run.update_column(:is_testing, true) }

  describe "#solo?" do
    it "is false for a team admission" do
      admission = TestAdmission.create!(:game_run => run, :team => create_team)
      admission.solo?.should be false
    end

    it "is true when a user is named" do
      admission = TestAdmission.create!(:game_run => run, :team => create_team,
                                        :user => create_user)
      admission.solo?.should be true
    end
  end

  it "refuses creation on a run that is not testing" do
    run.update_column(:is_testing, false)

    admission = TestAdmission.new(:game_run => run, :team => create_team)

    expect(admission).not_to be_valid
    expect(admission.errors[:game_run]).not_to be_empty
  end

  # The validation is :on => :create only, so teardown -- which clears
  # is_testing before it sweeps -- cannot be blocked by it.
  it "does not re-validate the testing flag on update" do
    admission = TestAdmission.create!(:game_run => run, :team => create_team)
    run.update_column(:is_testing, false)

    expect(admission.reload.save).to be true
  end

  describe "scopes" do
    it "of_run returns only that run's admissions" do
      mine  = TestAdmission.create!(:game_run => run, :team => create_team)
      other = create_game.current_run
      other.update_column(:is_testing, true)
      TestAdmission.create!(:game_run => other, :team => create_team)

      TestAdmission.of_run(run).to_a.should == [ mine ]
    end

    it "solo returns only admissions naming a user" do
      TestAdmission.create!(:game_run => run, :team => create_team)
      solo = TestAdmission.create!(:game_run => run, :team => create_team,
                                   :user => create_user)

      TestAdmission.of_run(run).solo.to_a.should == [ solo ]
    end
  end

  it "goes away with its run" do
    TestAdmission.create!(:game_run => run, :team => create_team)

    expect { run.destroy }.to change { TestAdmission.count }.by(-1)
  end
end

describe TestAdmission, ".admit_player!" do
  let(:game) { create_game }
  let(:run)  { game.current_run }
  let(:user) { create_user }

  before { run.update_column(:is_testing, true) }

  it "creates a disposable team with no members and no captain" do
    admission = TestAdmission.admit_player!(run, user)

    admission.solo?.should be true
    admission.team.members.should be_empty
    admission.team.captain.should be_nil
  end

  it "does not touch the player's real membership" do
    real = create_team(:captain => user)
    user.update!(:team => real)

    TestAdmission.admit_player!(run, user)

    user.reload.team_id.should == real.id
    real.reload.captain_id.should == user.id
  end

  it "names the team after the player and the run" do
    admission = TestAdmission.admit_player!(run, user)

    admission.team.name.should == "#{user.nickname} (test ##{run.id})"
  end

  it "suffixes the name when a real team already holds it" do
    Team.create!(:name => "#{user.nickname} (test ##{run.id})")

    admission = TestAdmission.admit_player!(run, user)

    admission.team.name.should == "#{user.nickname} (test ##{run.id})-2"
  end

  # Transactional: a disposable team with no admission is an orphan nothing
  # will ever sweep, because teardown finds them THROUGH their admissions.
  it "leaves no orphan team when the admission cannot be created" do
    TestAdmission.admit_player!(run, user)

    expect {
      expect { TestAdmission.admit_player!(run, user) }.to raise_error(ActiveRecord::RecordNotUnique)
    }.not_to change { Team.count }
  end
end
