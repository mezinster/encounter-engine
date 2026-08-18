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

  # The edit lands in the game AND the machine's output survives. Overwriting
  # proposed_text destroyed the only record of what the model produced, and
  # left `flags` -- computed against the original -- attached to text it was
  # never computed from. Provenance lives only in this table (design §5).
  it "lets the reviewer edit before accepting, without destroying the machine's output" do
    proposal = proposal_for(level, "name", "The frist")

    post accept_game_translation_run_proposal_path(game, run, proposal),
         :params => { :proposed_text => "The first" }

    expect(level.reload.translated("name", "en")).to eq("The first")
    expect(proposal.reload.accepted_text).to eq("The first")
    expect(proposal.proposed_text).to eq("The frist")
    expect(proposal.edited?).to be true
  end

  it "records no edit when the machine's text is accepted verbatim" do
    proposal = proposal_for(level, "name", "The first")

    post accept_game_translation_run_proposal_path(game, run, proposal),
         :params => { :proposed_text => "The first" }

    expect(proposal.reload.accepted_text).to eq("The first")
    expect(proposal.edited?).to be false
  end

  # A reviewer who clears the textarea means "don't use this". It used to mean
  # "silently accept the machine's words" -- the exact opposite, written into
  # a live game with nothing to show it happened.
  it "refuses a cleared textarea instead of quietly accepting the machine text" do
    proposal = proposal_for(level, "name", "The first")

    post accept_game_translation_run_proposal_path(game, run, proposal),
         :params => { :proposed_text => "" }

    expect(proposal.reload.state).to eq(TranslationProposal::PENDING)
    expect(ContentTranslation.where(:translatable => level, :locale => "en")).to be_empty
    expect(flash[:alert]).to eq(I18n.t("translations.review.blank_text"))
  end

  it "treats a textarea holding only a non-breaking space as cleared" do
    proposal = proposal_for(level, "name", "The first")

    post accept_game_translation_run_proposal_path(game, run, proposal),
         :params => { :proposed_text => " " }

    expect(proposal.reload.state).to eq(TranslationProposal::PENDING)
    expect(flash[:alert]).to eq(I18n.t("translations.review.blank_text"))
  end

  # Accept and Reject are drawn only on a pending row, because both actions
  # scope to .pending and this app installs no rescue_from for
  # RecordNotFound -- a button on a reviewed row is a 404 in production.
  it "stops offering Accept and Reject once a proposal has been reviewed" do
    proposal = proposal_for(level, "name", "The first")
    post accept_game_translation_run_proposal_path(game, run, proposal)

    get game_translation_run_proposals_path(game, run)

    expect(response.body).not_to include(
      accept_game_translation_run_proposal_path(game, run, proposal)
    )
    expect(response.body).not_to include(
      reject_game_translation_run_proposal_path(game, run, proposal)
    )
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

  # The counterpart action, for a reviewer who HAS read the flagged rows and
  # decided they are fine -- 15 quiz options that are brand names is a real
  # shape. It is deliberately a separate button from accept_all: sweeping the
  # flagged ones up silently is what would make the review step decorative.
  describe "accepting the flagged proposals in bulk" do
    it "accepts the flagged ones and leaves the unflagged for the other button" do
      clean   = proposal_for(level, "name", "The first")
      # "" is what an unflagged proposal actually carries in production --
      # Runner writes Flags.for(...).join(","), which is "" when nothing fired,
      # never nil. A scope that only knew about nil would sweep this one up.
      written = proposal_for(game, "name", "Night city", :flags => "")
      flagged = proposal_for(level, "text", "Найдите табличку", :flags => "identical")

      post accept_flagged_game_translation_run_proposals_path(game, run)

      expect(flagged.reload.state).to eq(TranslationProposal::ACCEPTED)
      expect(flagged.reviewed_by_id).to eq(superadmin.id)
      expect(level.reload.translated("text", "en")).to eq("Найдите табличку")
      expect(clean.reload.state).to eq(TranslationProposal::PENDING)
      expect(written.reload.state).to eq(TranslationProposal::PENDING)
    end

    # #accept refuses blank text outright -- "Reject is how you say no; blank
    # is a mistake, and it says so." accept_all could never meet one, because
    # blank output always carries `empty` and `unflagged` excluded it. This
    # button inverts that scope, so the empty set would otherwise be the one
    # set it is GUARANTEED to sweep up: ContentTranslation has no presence
    # validation on `value`, so each would write a blank row, leave the
    # pending list for good, and clear the `empty` check -- one of the five
    # the whole feature rests on -- in a single press.
    it "will not accept blank machine output, even though it is flagged" do
      blank = proposal_for(level, "name", "", :flags => "empty")
      other = proposal_for(level, "text", "Найдите табличку", :flags => "identical")

      post accept_flagged_game_translation_run_proposals_path(game, run)

      expect(other.reload.state).to eq(TranslationProposal::ACCEPTED)
      expect(blank.reload.state).to eq(TranslationProposal::PENDING)
      expect(ContentTranslation.find_by(:translatable => level, :field => "name",
                                        :locale => "en")).to be_nil
    end

    # The audit log is the only place this is visible afterwards, and a bypass
    # of the review gate must not read like a routine bulk accept.
    it "records that the accepted proposals were flagged ones" do
      proposal_for(level, "name", "The first",         :flags => "identical")
      proposal_for(level, "text", "Найдите табличку", :flags => "identical,length")

      expect { post accept_flagged_game_translation_run_proposals_path(game, run) }
        .to change { AdminAction.count }.by(1)

      entry = AdminAction.newest_first.first
      expect(entry.action).to eq("translation_proposals_accepted")
      # The flag KINDS, not a count that would only ever repeat proposals=.
      # An investigator reading this later wants to know what was waved
      # through, and "identical" and "lost_digits" are very different answers.
      expect(entry.details).to eq("run=#{run.id} proposals=2 flagged=identical,length")
    end

    it "refuses a non-superadmin" do
      proposal_for(level, "name", "The first", :flags => "identical")
      sign_in(create_user)

      post accept_flagged_game_translation_run_proposals_path(game, run)

      expect(response).to have_http_status(:unauthorized)
    end
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

  # The review record and the game must never disagree about whether the
  # machine text was accepted. This app installs no rescue_from for
  # RecordNotFound (see level_authorization_spec.rb and five other files), so
  # a request spec sees the exception itself rather than a rendered 404.
  it "refuses to reject a proposal that was already accepted, leaving its translation intact" do
    proposal = proposal_for(level, "name", "The first")
    post accept_game_translation_run_proposal_path(game, run, proposal)

    expect { post reject_game_translation_run_proposal_path(game, run, proposal) }
      .to raise_error(ActiveRecord::RecordNotFound)

    expect(proposal.reload.state).to eq(TranslationProposal::ACCEPTED)
    expect(level.reload.translated("name", "en")).to eq("The first")
  end

  # Every other fixture in this feature is :is_draft => true, which is exactly
  # why this bug survived review: Game#game_starts_in_the_future only fires on
  # a NON-draft game, and a draft is exempt. The authoring forms never meet it
  # because GamesController gates edits behind ensure_game_was_not_started;
  # this controller has no such filter, so accepting a Game-level proposal on
  # a game currently being played raised RecordInvalid -> 500, and inside
  # accept_all it aborted mid-loop having already applied some proposals and
  # written no audit entry at all.
  describe "on a game that has already started" do
    let(:started) do
      g = create_game(:is_draft => true, :primary_locale => "ru",
                      :available_locale_list => %w[ru en])
      create_level(:game => g, :name => "Первый", :text => "Найдите табличку")
      # Past starts_at plus non-draft is precisely what the validation refuses.
      # update_column, because saving it through the model would trip the very
      # validation under test -- and via current_run, because the eight
      # scheduling columns live on GameRun now and Game only delegates to them.
      g.current_run.update_column(:starts_at, 2.hours.ago)
      g.update_column(:is_draft, false)
      g.reload
    end

    let(:started_run) do
      TranslationRun.create!(:game => started, :actor => superadmin,
                             :model => "claude-opus-5",
                             :state => TranslationRun::SUCCEEDED,
                             :target_locale_list => %w[en])
    end

    def started_proposal(record, field, text, flags: nil)
      TranslationProposal.create!(:translation_run => started_run, :translatable => record,
                                  :field => field, :locale => "en",
                                  :source_text => record[field].to_s, :proposed_text => text,
                                  :flags => flags, :state => TranslationProposal::PENDING)
    end

    it "confirms the fixture really is one the validation refuses" do
      # A guard on the guard. If create_game ever stops producing a game the
      # validation rejects, every example below passes vacuously.
      started.name = "Whatever"
      expect(started).not_to be_valid
      expect(started.errors[:starts_at]).to be_present
    end

    it "refuses a Game-level proposal cleanly instead of raising a 500" do
      proposal = started_proposal(started, "name", "Night city")

      expect { post accept_game_translation_run_proposal_path(started, started_run, proposal) }
        .not_to raise_error

      expect(response).to redirect_to(
        game_translation_run_proposals_path(started, started_run)
      )
      expect(flash[:alert]).to be_present
      expect(proposal.reload.state).to eq(TranslationProposal::PENDING)
    end

    # A Level-level proposal has no such problem, which is what makes the
    # half-application possible: accept_all applies it, then dies on the Game
    # one. The transaction is what stops that.
    it "applies nothing at all when accept_all hits an invalid record" do
      level_proposal = started_proposal(started.levels.first, "name", "The first")
      started_proposal(started, "name", "Night city")

      expect { post accept_all_game_translation_run_proposals_path(started, started_run) }
        .not_to raise_error

      expect(level_proposal.reload.state).to eq(TranslationProposal::PENDING)
      expect(ContentTranslation.where(:locale => "en").count).to eq(0)
      expect(flash[:alert]).to be_present
    end

    # Same all-or-nothing guarantee for the flagged button. It shares the
    # transaction with accept_all, and this is what proves the sharing is real
    # rather than two loops that happen to look alike.
    it "applies nothing at all when accept_flagged hits an invalid record" do
      level_proposal = started_proposal(started.levels.first, "name", "The first",
                                        :flags => "identical")
      started_proposal(started, "name", "Night city", :flags => "identical")

      expect { post accept_flagged_game_translation_run_proposals_path(started, started_run) }
        .not_to raise_error

      expect(level_proposal.reload.state).to eq(TranslationProposal::PENDING)
      expect(ContentTranslation.where(:locale => "en").count).to eq(0)
      expect(flash[:alert]).to be_present
    end

    it "writes no audit entry for a bulk acceptance that applied nothing" do
      started_proposal(started.levels.first, "name", "The first")
      started_proposal(started, "name", "Night city")

      expect { post accept_all_game_translation_run_proposals_path(started, started_run) }
        .not_to change { AdminAction.count }
    end

    # The other half of "either succeeds or refuses cleanly": a live game's
    # LEVEL text is translatable without tripping the game's own validation,
    # and must still go through.
    it "still accepts a proposal on a record the validation does not touch" do
      proposal = started_proposal(started.levels.first, "name", "The first")

      post accept_game_translation_run_proposal_path(started, started_run, proposal)

      expect(proposal.reload.state).to eq(TranslationProposal::ACCEPTED)
      expect(started.levels.first.reload.translated("name", "en")).to eq("The first")
    end
  end

  it "refuses to accept the same proposal twice" do
    proposal = proposal_for(level, "name", "The first")
    post accept_game_translation_run_proposal_path(game, run, proposal)

    expect {
      expect { post accept_game_translation_run_proposal_path(game, run, proposal) }
        .to raise_error(ActiveRecord::RecordNotFound)
    }.not_to change { AdminAction.count }
  end
end
