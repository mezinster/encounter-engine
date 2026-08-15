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
