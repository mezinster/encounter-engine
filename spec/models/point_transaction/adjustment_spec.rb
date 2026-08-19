require "rails_helper"

describe PointTransaction do
  let(:actor) { create_user }

  describe ".adjust!" do
    it "writes a global row with no game and no attempt" do
      team = create_team(:captain => create_user)

      row = PointTransaction.adjust!(:team => team, :amount => -50,
                                     :note => "Ушли с точки, не дождавшись судьи",
                                     :actor => actor)

      expect(row.game_id).to be_nil
      expect(row.game_passing_id).to be_nil
      expect(row.level_id).to be_nil
      expect(row.team_id).to eq(team.id)
      expect(row.reason).to eq("adjustment")
      expect(row.created_by_id).to eq(actor.id)
      expect(team.balance).to eq(-50)
    end

    it "denormalises the game and team from a passing when one is given" do
      passing = create_game_passing

      row = PointTransaction.adjust!(:team => passing.team, :amount => 20,
                                     :note => "Точка была закрыта", :actor => actor,
                                     :passing => passing)

      expect(row.game_passing_id).to eq(passing.id)
      expect(row.game_id).to eq(passing.game_id)
      expect(row.team_id).to eq(passing.team_id)
    end

    # The index change. Without it the second call raises RecordNotUnique,
    # because the per-attempt index covers every reason with a NULL level_id.
    it "allows more than one adjustment on the same attempt" do
      passing = create_game_passing

      PointTransaction.adjust!(:team => passing.team, :amount => -10, :note => "a",
                               :actor => actor, :passing => passing)
      PointTransaction.adjust!(:team => passing.team, :amount => -10, :note => "b",
                               :actor => actor, :passing => passing)

      expect(PointTransaction.where(:game_passing_id => passing.id,
                                    :reason => "adjustment").count).to eq(2)
    end

    it "allows more than one global adjustment for the same team" do
      team = create_team(:captain => create_user)

      PointTransaction.adjust!(:team => team, :amount => 5,  :note => "a", :actor => actor)
      PointTransaction.adjust!(:team => team, :amount => -5, :note => "b", :actor => actor)

      expect(team.point_transactions.count).to eq(2)
      expect(team.balance).to eq(0)
    end

    # The narrowed index is SHARED with three reasons that depend on it for
    # idempotence. Narrowing it for adjustments must not have narrowed it for
    # them -- and an example per reason, because `reason <> 'adjustment'` is one
    # clause protecting three separate guarantees, and a typo in it would
    # release all three at once while every adjustment example stayed green.
    %w[level_completed game_completed].each do |reason|
      it "still refuses a duplicate #{reason} on the same attempt" do
        passing = create_game_passing
        level   = reason == "level_completed" ? passing.current_level : nil

        first  = PointTransaction.award!(:passing => passing, :reason => reason,
                                         :level => level, :amount => 10)
        second = PointTransaction.award!(:passing => passing, :reason => reason,
                                         :level => level, :amount => 10)

        expect(first).to be_persisted
        expect(second).to be_nil
        expect(PointTransaction.where(:game_passing_id => passing.id,
                                      :reason => reason).count).to eq(1)
      end
    end

    it "still refuses a duplicate level_skipped on the same level" do
      passing = create_game_passing
      level   = passing.current_level

      first  = PointTransaction.award!(:passing => passing, :reason => "level_skipped",
                                       :level => level, :amount => -5)
      second = PointTransaction.award!(:passing => passing, :reason => "level_skipped",
                                       :level => level, :amount => -5)

      expect(first).to be_persisted
      expect(second).to be_nil
    end

    # A5: award! rescues RecordNotUnique and returns nil, which is right for an
    # idempotent award and wrong for an adjustment. adjust! must raise.
    it "does not swallow a constraint violation" do
      team = create_team(:captain => create_user)
      allow(PointTransaction).to receive(:create!)
        .and_raise(ActiveRecord::RecordNotUnique.new("boom"))

      expect {
        PointTransaction.adjust!(:team => team, :amount => 1, :note => "x", :actor => actor)
      }.to raise_error(ActiveRecord::RecordNotUnique)
    end
  end

  describe "validations on adjustment rows" do
    it "requires a note" do
      team = create_team(:captain => create_user)
      row  = PointTransaction.new(:team => team, :amount => -1, :reason => "adjustment")

      expect(row).not_to be_valid
      expect(row.errors[:note]).not_to be_empty
    end

    it "refuses a zero amount" do
      team = create_team(:captain => create_user)
      row  = PointTransaction.new(:team => team, :amount => 0, :reason => "adjustment",
                                  :note => "x")

      expect(row).not_to be_valid
      expect(row.errors[:amount]).not_to be_empty
    end

    # The validations are conditional on the reason, so every row written by
    # D1 and D2 -- none of which has a note -- must still be valid.
    it "does not impose either rule on an award" do
      passing = create_game_passing
      row = PointTransaction.award!(:passing => passing, :reason => "level_completed",
                                    :level => passing.current_level, :amount => 0)

      expect(row).to be_persisted
      expect(row.note).to be_nil
    end

    # Relaxing the two belongs_to associations to :optional must not relax them
    # for the writers that should still require them.
    it "still refuses an award with no passing" do
      row = PointTransaction.new(:team => create_team(:captain => create_user),
                                 :amount => 10, :reason => "level_completed")

      expect(row).not_to be_valid
      expect(row.errors[:game_passing]).not_to be_empty
    end
  end
end
