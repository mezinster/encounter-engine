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

    # These three examples guard three real regressions, but not through the
    # same index. `level_completed` and `level_skipped` always carry a real
    # `level`, so their duplicate is caught by the untouched sibling index,
    # `index_point_transactions_per_level` (WHERE level_id IS NOT NULL) -- the
    # narrowed `per_attempt` index this task changed never enters into it.
    # `game_completed` is the only one of the three with a NULL level, so it
    # is the only one actually exercising the narrowed `per_attempt` index
    # and its `AND reason <> 'adjustment'` clause.
    #
    # Concretely: corrupting that clause (verified by mutation) reddens only
    # the `game_completed` example below -- `level_completed` and
    # `level_skipped` stay green throughout, because `per_level` alone already
    # protects them. A future reader seeing green on all three after such a
    # mutation should not conclude the clause is untouched; only
    # `game_completed`'s result says anything about it. All three examples
    # are kept regardless, because each guards a real, independent
    # idempotence guarantee -- just not all through the same index.
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

  # B1. The per-ATTEMPT index was narrowed for adjustments; the per-LEVEL one
  # was not. Nothing writes a level-scoped adjustment today -- adjust! always
  # sets level_id nil -- so this is unreachable, and it is exactly the kind of
  # unreachable trap that fires the moment section 8's deferred level-scoped
  # adjustment is built: adjust! does not rescue, so the second one would 500.
  describe "the per-level index" do
    it "allows more than one adjustment on the same level" do
      passing = create_game_passing
      level   = passing.current_level

      2.times do |n|
        PointTransaction.create!(:team_id => passing.team_id, :game_id => passing.game_id,
                                 :game_passing_id => passing.id, :level_id => level.id,
                                 :amount => -5, :reason => "adjustment",
                                 :note => "row #{n}")
      end

      expect(PointTransaction.where(:level_id => level.id,
                                    :reason => "adjustment").count).to eq(2)
    end

    it "still refuses a duplicate level_completed on the same level" do
      passing = create_game_passing
      level   = passing.current_level

      first  = PointTransaction.award!(:passing => passing, :reason => "level_completed",
                                       :level => level, :amount => 10)
      second = PointTransaction.award!(:passing => passing, :reason => "level_completed",
                                       :level => level, :amount => 10)

      expect(first).to be_persisted
      expect(second).to be_nil
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
