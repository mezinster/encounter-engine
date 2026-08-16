require "rails_helper"

describe TranslationRun, ".sweep_stale!" do
  let(:game)  { create_game }
  let(:actor) { u = create_user; u.update!(:is_superadmin => true); u }

  def run_with(state, updated_at)
    run = TranslationRun.create!(:game => game, :actor => actor,
                                 :model => "claude-opus-5", :state => state)
    run.update_column(:updated_at, updated_at)
    run
  end

  # A thread killed by a deploy leaves its run in `running` forever, and
  # `one active run per game` then locks the game out of translation
  # permanently. The sweep is what stops a deploy from being a trap.
  it "fails a run that has made no progress for too long" do
    stale = run_with(TranslationRun::RUNNING, 30.minutes.ago)

    expect(TranslationRun.sweep_stale!).to eq(1)
    expect(stale.reload.state).to eq(TranslationRun::FAILED)
    expect(stale.error_message).to be_present
  end

  it "leaves a run that is still making progress alone" do
    fresh = run_with(TranslationRun::RUNNING, 1.minute.ago)

    expect(TranslationRun.sweep_stale!).to eq(0)
    expect(fresh.reload.state).to eq(TranslationRun::RUNNING)
  end

  it "leaves terminal runs alone however old they are" do
    done = run_with(TranslationRun::SUCCEEDED, 1.year.ago)

    TranslationRun.sweep_stale!
    expect(done.reload.state).to eq(TranslationRun::SUCCEEDED)
  end
end
