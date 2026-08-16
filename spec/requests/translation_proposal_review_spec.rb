require "rails_helper"

describe "reviewing translation proposals", type: :request do
  let(:superadmin) { u = create_user; u.update!(:is_superadmin => true); u }
  # is_draft: true, deliberately -- the established pattern for a game that
  # declares a non-primary locale before it has been translated (see
  # translated_level_spec.rb, authoring_translations_spec.rb). Without it,
  # create_game! trips declared_locales_are_translated_before_publication:
  # a NON-draft game declaring "en" with no English content anywhere is
  # exactly what that gate exists to refuse, and the brief's spec was
  # missing this option.
  let(:game)       { create_game(:is_draft => true, :primary_locale => "ru",
                                 :available_locale_list => %w[ru en]) }
  let!(:level)     { create_level(:game => game, :name => "Первый", :text => "Найдите табличку") }
  let(:run) do
    TranslationRun.create!(:game => game, :actor => superadmin, :model => "claude-opus-5",
                           :state => TranslationRun::SUCCEEDED, :target_locale_list => %w[en])
  end

  def sign_in(user)
    put login_path, :params => { :email => user.email, :password => "1234" }
  end

  def proposal_for(record, field, text, flags: nil)
    TranslationProposal.create!(:translation_run => run, :translatable => record,
                                :field => field, :locale => "en",
                                :source_text => record[field].to_s, :proposed_text => text,
                                :flags => flags, :state => TranslationProposal::PENDING)
  end

  before do
    allow(Translation::Client).to receive(:configured?).and_return(true)
    sign_in(superadmin)
  end

  # The whole requirement in one assertion: an accepted proposal is
  # indistinguishable from a hand-typed translation, because it goes through
  # the same setter the authoring form uses.
  it "writes a ContentTranslation indistinguishable from a hand-typed one" do
    proposal = proposal_for(level, "name", "The first")

    post accept_game_translation_run_proposal_path(game, run, proposal)

    expect(proposal.reload.state).to eq(TranslationProposal::ACCEPTED)
    expect(proposal.reviewed_by_id).to eq(superadmin.id)
    expect(level.reload.translated("name", "en")).to eq("The first")

    row = ContentTranslation.find_by(:translatable => level, :field => "name", :locale => "en")
    expect(row.value).to eq("The first")
    # No provenance column on content_translations. The game cannot tell.
    expect(ContentTranslation.column_names).not_to include("source", "translation_run_id")
  end

  it "lets the reviewer edit before accepting" do
    proposal = proposal_for(level, "name", "The frist")

    post accept_game_translation_run_proposal_path(game, run, proposal),
         :params => { :proposed_text => "The first" }

    expect(level.reload.translated("name", "en")).to eq("The first")
    expect(proposal.reload.proposed_text).to eq("The first")
  end

  it "writes nothing when a proposal is rejected" do
    proposal = proposal_for(level, "name", "Первый")

    post reject_game_translation_run_proposal_path(game, run, proposal)

    expect(proposal.reload.state).to eq(TranslationProposal::REJECTED)
    expect(ContentTranslation.where(:translatable => level, :locale => "en")).to be_empty
  end

  # Accept-all is the bulk action, and it must never sweep up a flagged
  # proposal -- the flags exist precisely because those need a human eye.
  it "accepts every unflagged proposal and leaves flagged ones alone" do
    clean   = proposal_for(level, "name", "The first")
    flagged = proposal_for(level, "text", "Найдите табличку", :flags => "identical")

    post accept_all_game_translation_run_proposals_path(game, run)

    expect(clean.reload.state).to eq(TranslationProposal::ACCEPTED)
    expect(flagged.reload.state).to eq(TranslationProposal::PENDING)
  end

  it "completes the publish gate once every proposal is accepted" do
    proposal_for(game,  "name",        "Night city")
    proposal_for(game,  "description", "A city game")
    proposal_for(level, "name",        "The first")
    proposal_for(level, "text",        "Find the sign")

    post accept_all_game_translation_run_proposals_path(game, run)

    expect(game.reload.translations_complete?).to be true
  end

  it "refuses a non-superadmin" do
    proposal = proposal_for(level, "name", "The first")
    sign_in(create_user)

    post accept_game_translation_run_proposal_path(game, run, proposal)
    # 401, not 403: deny_unauthorized renders :unauthorized for every
    # Authentication::Unauthorized this app raises. See Task 7's spec.
    expect(response).to have_http_status(:unauthorized)
  end
end
