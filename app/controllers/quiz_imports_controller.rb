# -*- encoding : utf-8 -*-
#
# Paste → preview → confirm, for turning a block of written questions into
# quiz levels. Replaces a console script that had to be run over SSH; see
# docs/superpowers/specs/2026-08-09-quiz-bulk-import-design.md.
#
# One action carries both steps, keyed on params[:confirm], so no
# server-side state has to survive between them: the pasted text rides a
# hidden field in the preview form. A session or a scratch table would both
# outlive the tab that abandoned them.
class QuizImportsController < ApplicationController
  include SecurityFilters

  # Exactly the chain LevelsController uses. ensure_author already admits
  # superadmins, so both halves of the original request are covered by a
  # filter that already existed; and an author who cannot add a level to a
  # started game cannot bulk-import into one either.
  before_action :find_game
  before_action :ensure_author
  before_action :ensure_editing_not_locked
  before_action :ensure_game_was_not_started

  def new
    @text = ""
  end

  def create
    @text = params[:text].to_s
    @parsed = QuizImport.new(@text)

    unless @parsed.valid?
      render :new, status: :unprocessable_entity and return
    end

    @writer = QuizImport::Writer.new(@game, @parsed.questions)

    # No confirmation yet: show what would happen and write nothing.
    render :preview and return unless params[:confirm].present?

    created = @writer.import!

    redirect_to game_path(@game),
                :notice => t("quiz_imports.created_notice",
                             :added => created.size, :skipped => @writer.skipped.size)
  end

  private

  def find_game
    @game = Game.find(params[:game_id])
  end
end
