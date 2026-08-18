# -*- encoding : utf-8 -*-
#
# Reviewing what the model produced, before any of it reaches a live game.
#
# Accepting writes through TranslatableContent#translations_attributes=, the
# same setter GamesController, LevelsController, HintsController and
# OptionsController use for a hand-typed translation. That is deliberate: the
# stored ContentTranslation row is byte-identical to a human's, and the
# provenance lives only in translation_proposals, which the game never reads.
class TranslationProposalsController < ApplicationController
  include SecurityFilters
  include AdminAudit

  before_action :require_authentication!
  before_action :require_superadmin!
  before_action :load_run

  def index
    @proposals = @run.translation_proposals
                     .includes(:translatable)
                     .order(:locale, :translatable_type, :translatable_id, :field)
  end

  def accept
    # .pending, not a bare find: without it, rejecting an already-ACCEPTED
    # proposal marks it rejected while leaving the ContentTranslation it wrote
    # live in the game -- the review record and the game disagreeing about
    # whether the machine text was accepted. Accepting twice would likewise
    # write a second audit entry for one change.
    proposal = @run.translation_proposals.pending.find(params[:id])
    text     = submitted_text(proposal)

    # Fail loudly. This used to be `params[:proposed_text].presence ||
    # proposal.proposed_text`, so a reviewer who cleared the textarea meaning
    # "don't use this" silently accepted the machine text instead -- the exact
    # opposite of what they did, written into a live game with no sign it
    # happened. Reject is how you say no; blank is a mistake, and it says so.
    if blank_text?(text)
      flash[:alert] = t("translations.review.blank_text")
      return redirect_to(game_translation_run_proposals_path(@game, @run))
    end

    begin
      apply!(proposal, text)
    rescue ActiveRecord::RecordInvalid => e
      flash[:alert] = t("translations.review.invalid",
                        :message => e.record.errors.full_messages.to_sentence)
      return redirect_to(game_translation_run_proposals_path(@game, @run))
    end

    record_admin_action("translation_proposals_accepted", @game,
                        "run=#{@run.id} proposals=1 locale=#{proposal.locale}")
    redirect_to game_translation_run_proposals_path(@game, @run)
  end

  def reject
    # .pending, not a bare find: see the comment in #accept.
    proposal = @run.translation_proposals.pending.find(params[:id])
    proposal.update!(:state => TranslationProposal::REJECTED,
                     :reviewed_by => current_user, :reviewed_at => Time.now)

    redirect_to game_translation_run_proposals_path(@game, @run)
  end

  # Never sweeps up a flagged proposal. The flags exist precisely because those
  # are the ones a human has to look at, and a bulk action that ignored them
  # would make the whole review step decorative.
  def accept_all
    bulk_accept!(@run.translation_proposals.pending.unflagged) do |count|
      "run=#{@run.id} proposals=#{count}"
    end
  end

  # The flagged ones, in bulk, on purpose -- for the reviewer who has read them
  # and decided they are fine. That is a real shape: one run produced 15
  # `identical` flags that were all quiz options naming brands, and clearing
  # them one at a time is the kind of chore that teaches a reviewer to stop
  # reading.
  #
  # Deliberately a SEPARATE action from accept_all rather than a wider scope on
  # it: pressing "accept everything" must never be how a flagged proposal gets
  # in, and the audit entry has to say which of the two happened.
  def accept_flagged
    bulk_accept!(@run.translation_proposals.pending.flagged) do |count|
      "run=#{@run.id} proposals=#{count} flagged=#{count}"
    end
  end

  private

  # All or nothing. apply! runs the record's FULL validation set, and a
  # Game-level proposal on a game that has already started fails
  # Game#game_starts_in_the_future -- a validation the authoring forms never
  # meet because GamesController gates edits behind ensure_game_was_not_started
  # and this controller has no such filter. Un-transacted, the loop applied
  # some proposals, raised on one, 500ed, and wrote NO audit entry: a game
  # half-translated by an action that reported nothing at all. Every spec
  # fixture is a draft, so neither suite could see it.
  def bulk_accept!(scope)
    accepted = scope.to_a

    begin
      TranslationProposal.transaction do
        accepted.each { |proposal| apply!(proposal, proposal.proposed_text) }
      end
    rescue ActiveRecord::RecordInvalid => e
      flash[:alert] = t("translations.review.invalid",
                        :message => e.record.errors.full_messages.to_sentence)
      return redirect_to(game_translation_run_proposals_path(@game, @run))
    end

    record_admin_action("translation_proposals_accepted", @game, yield(accepted.size))
    redirect_to game_translation_run_proposals_path(@game, @run)
  end

  def load_run
    @game = Game.find(params[:game_id])
    @run  = @game.translation_runs.find(params[:translation_run_id])
  end

  # params.key?, not .presence: a submitted-but-empty textarea has to be
  # distinguishable from a form that carried no textarea at all (accept_all).
  def submitted_text(proposal)
    params.key?(:proposed_text) ? params[:proposed_text].to_s : proposal.proposed_text
  end

  # Unicode-aware, for the same reason Translation::Flags is: String#strip
  # leaves a lone non-breaking space standing, and a translation of one NBSP
  # is blank by any meaning a reviewer has in mind.
  def blank_text?(text)
    text.to_s.gsub(/[[:space:]]/, "").empty?
  end

  # Raises on invalid. Callers decide whether that is a flash (accept) or a
  # rollback (accept_all); neither may be a 500.
  def apply!(proposal, text)
    record = proposal.translatable
    record.translations_attributes = { proposal.locale => { proposal.field => text } }
    record.save!

    # accepted_text, NOT proposed_text. proposed_text is the machine's output
    # and is immutable: overwriting it left `flags` -- computed against the
    # original -- attached to text it was never computed from, and destroyed
    # the only record of what the model actually produced. See the migration
    # comment on translation_proposals.accepted_text.
    proposal.update!(:accepted_text => text, :state => TranslationProposal::ACCEPTED,
                     :reviewed_by => current_user, :reviewed_at => Time.now)
  end
end
