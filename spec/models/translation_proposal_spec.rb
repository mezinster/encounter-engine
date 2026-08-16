require "rails_helper"

describe TranslationProposal do
  let(:game)  { create_game }
  let(:actor) { u = create_user; u.update!(:is_superadmin => true); u }
  let(:run) do
    TranslationRun.create!(:game => game, :actor => actor,
                           :state => TranslationRun::RUNNING, :model => "claude-opus-5")
  end
  let(:level) { create_level(:game => game) }

  def build_proposal(attrs = {})
    TranslationProposal.new({ :translation_run => run, :translatable => level,
                              :field => "text", :locale => "en",
                              :source_text => "Найдите табличку",
                              :proposed_text => "Find the sign",
                              :state => "pending" }.merge(attrs))
  end

  it "round-trips flags through a comma-joined column" do
    proposal = build_proposal
    proposal.flag_list = %w[identical length]

    expect(proposal.flags).to eq("identical,length")
    expect(proposal.flag_list).to eq(%w[identical length])
    expect(proposal.flagged?).to be true
  end

  it "is unflagged when the column is blank" do
    proposal = build_proposal(:flags => nil)

    expect(proposal.flag_list).to eq([])
    expect(proposal.flagged?).to be false
  end

  it "scopes to pending and to unflagged separately" do
    clean   = build_proposal.tap(&:save!)
    flagged = build_proposal(:field => "name", :flags => "identical").tap(&:save!)
    done    = build_proposal(:locale => "pl", :state => "accepted").tap(&:save!)

    expect(TranslationProposal.pending).to match_array([ clean, flagged ])
    expect(TranslationProposal.pending.unflagged).to eq([ clean ])
    expect(done.state).to eq("accepted")
  end

  # The unique index is what makes a killed run resumable instead of
  # duplicating work -- it is load-bearing, not hygiene.
  it "refuses a second proposal for the same field and locale in one run" do
    build_proposal.save!

    expect { build_proposal.save!(:validate => false) }
      .to raise_error(ActiveRecord::RecordNotUnique)
  end
end
