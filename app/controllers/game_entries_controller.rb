# -*- encoding : utf-8 -*-
class GameEntriesController < ApplicationController
  include SecurityFilters

  before_action :require_authentication!
  before_action :find_game, only: :new
  before_action :find_team, only: :new
  before_action :find_entry, except: :new
  before_action :ensure_author, only: [:accept, :reject]
  before_action :ensure_team_captain, except: [:accept, :reject]

  def new
    if @game.can_request?
      @game_entry = GameEntry.create!(status: "new", game: @game, team: @team)
      @game.reserve_place_for_team!
    end
    redirect_to dashboard_path
  end

  def reopen
    if @game.can_request?
      @entry.reopen! unless @entry.status == "accepted"
      @game.reserve_place_for_team!
    end
    redirect_to dashboard_path
  end

  def accept
    @entry.accept! if @entry.status == "new"
    redirect_to dashboard_path
  end

  def reject
    @entry.reject! if @entry.status == "new"
    @game.free_place_of_team!
    redirect_to dashboard_path
  end

  def recall
    @entry.recall! if @entry.status == "new"
    @game.free_place_of_team!
    redirect_to dashboard_path
  end

  def cancel
    @entry.cancel! if @entry.status == "accepted"
    @game.free_place_of_team!
    redirect_to dashboard_path
  end

  private

  # No params[:game_entry] anywhere in this controller -- every action
  # resolves @game/@team/@entry from route id segments (see config/routes.rb),
  # not from a submitted form, so there is no strong-parameters hole to close
  # here.
  def find_game
    @game = Game.find(params[:game_id])
  end

  def find_team
    @team = Team.find(params[:team_id])
  end

  def find_entry
    @entry = GameEntry.find(params[:id])
    @game = Game.find(@entry.game.id) if @entry
  end
end
