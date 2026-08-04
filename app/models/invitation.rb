# -*- encoding : utf-8 -*-
class Invitation < ApplicationRecord
  belongs_to :to_team, :class_name => "Team", optional: true
  belongs_to :for_user, :class_name => "User", optional: true

  scope :for, ->(user) { where(for_user_id: user.id) }

  attr_accessor :recepient_nickname

  validates :for_user, presence: true
  validates :recepient_nickname, presence: true
  validates :for_user_id, uniqueness: { scope: :to_team_id }

  validate :recepient_is_not_member_of_any_team

  before_validation :find_user

  scope :for_user, ->(user) { where(for_user_id: user.id) }
  scope :to_team, ->(team) { where(to_team_id: team.id) }

  protected

  def find_user
    self.for_user = User.where(nickname: recepient_nickname).first
  end

  def recepient_is_not_member_of_any_team
    errors.add(:base, :recipient_already_team_member) if for_user and for_user.member_of_any_team?
  end
end
