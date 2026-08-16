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
    apply(proposal, params[:proposed_text].presence || proposal.proposed_text)

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
    accepted = @run.translation_proposals.pending.unflagged.to_a
    accepted.each { |proposal| apply(proposal, proposal.proposed_text) }

    record_admin_action("translation_proposals_accepted", @game,
                        "run=#{@run.id} proposals=#{accepted.size}")
    redirect_to game_translation_run_proposals_path(@game, @run)
  end

  private

  def load_run
    @game = Game.find(params[:game_id])
    @run  = @game.translation_runs.find(params[:translation_run_id])
  end

  def apply(proposal, text)
    record = proposal.translatable
    record.translations_attributes = { proposal.locale => { proposal.field => text } }
    record.save!

    proposal.update!(:proposed_text => text, :state => TranslationProposal::ACCEPTED,
                     :reviewed_by => current_user, :reviewed_at => Time.now)
  end
end
