# -*- encoding : utf-8 -*-
class AddAnsweredQuestionsToGamePassing < ActiveRecord::Migration[4.2]
  def self.up
    add_column :game_passings, :answered_questions, :string
  end

  def self.down
    remove_column :game_passings, :answered_questions
  end
end
