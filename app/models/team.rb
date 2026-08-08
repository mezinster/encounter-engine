# -*- encoding : utf-8 -*-
class Team < ApplicationRecord
  has_many :game_entries, :class_name => "GameEntry"
  has_many :game_passings, :class_name => "GamePassing"
  has_many :members, :class_name => "User"
  belongs_to :captain, :class_name => "User", optional: true

  validates :name, presence: true, uniqueness: true

  after_save :adopt_captain

  def current_level_in(game)
    game_passing = GamePassing.of(self, game)
    game_passing.try :current_level
  end

  def finished?(game)
    game_passing = GamePassing.of(self, game)
    !! game_passing.try(:finished?)
  end

  protected

  def adopt_captain
    unless captain.nil?
      self.members << captain unless members.include?(captain)
    end
  end
end
