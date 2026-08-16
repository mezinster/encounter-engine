require "rails_helper"

describe TranslationRun do
  let(:game)  { create_game }
  let(:actor) { u = create_user; u.update!(:is_superadmin => true); u }

  # actor_id is null: false in the schema and belongs_to is required by
  # default, so every persisted run needs one.
  def persisted_run(attrs = {})
    TranslationRun.create!({ :game => game, :actor => actor,
                             :model => "claude-opus-5" }.merge(attrs))
  end

  # Comma-joined, not serialised: the same convention games.available_locales
  # uses, for the same reason -- it must be readable in a database console
  # during an incident.
  it "round-trips the target locale list through a comma-joined column" do
    run = TranslationRun.new(:game => game)
    run.target_locale_list = %w[en pl]

    expect(run.target_locales).to eq("en,pl")
    expect(run.target_locale_list).to eq(%w[en pl])
  end

  it "treats a blank column as an empty list rather than [\"\"]" do
    expect(TranslationRun.new(:game => game, :target_locales => "").target_locale_list).to eq([])
  end

  it "knows which states are terminal" do
    expect(TranslationRun.new(:state => "running").terminal?).to be false
    expect(TranslationRun.new(:state => "pending").terminal?).to be false
    %w[succeeded failed cancelled].each do |state|
      expect(TranslationRun.new(:state => state).terminal?).to be true
    end
  end

  it "reports progress as a fraction, and does not divide by zero on an empty run" do
    expect(TranslationRun.new(:fields_total => 0,  :fields_done => 0).progress_fraction).to eq(0.0)
    expect(TranslationRun.new(:fields_total => 80, :fields_done => 20).progress_fraction).to eq(0.25)
  end

  # One run per game at a time. Without this the pre-flight estimate, the
  # per-field cost cap and the audit trail all describe a world where a single
  # run is in flight, while two threads race to write proposals for the same
  # (record, field, locale).
  it "finds an in-flight run for a game and ignores terminal ones" do
    finished = persisted_run(:state => TranslationRun::SUCCEEDED)
    expect(TranslationRun.active_for(game)).to be_empty

    running = persisted_run(:state => TranslationRun::RUNNING)
    expect(TranslationRun.active_for(game).to_a).to eq([ running ])

    expect(finished.terminal?).to be true
  end

  it "requires the actor the schema insists on" do
    expect { TranslationRun.create!(:game => game, :model => "claude-opus-5") }
      .to raise_error(ActiveRecord::RecordInvalid)
  end
end
