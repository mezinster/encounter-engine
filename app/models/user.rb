# -*- encoding : utf-8 -*-
class User < ApplicationRecord
  belongs_to :team, optional: true

  has_many :created_games, :class_name => "Game", :foreign_key => "author_id"

  # password/password_confirmation are virtual attributes backed by the
  # crypted_password + salt columns. The Merb app got these, plus
  # #password_required?, from merb-auth's SaltedUser mixin, included into
  # User at boot (merb/merb-auth/setup.rb) rather than declared in this file.
  # Task 6 (Authentication) replaces this with real hashing (encrypt_password,
  # authenticate); this is only enough for the validations below to run.
  attr_accessor :password, :password_confirmation

  # The dot in the domain group is escaped, which an earlier version (before
  # d21a177, "Upgrade to ActiveRecord 4.0") was not: an unescaped . matches
  # any character, so "user@localhost" passed by consuming the final "t" as
  # the separator. No address used anywhere in the suites is affected by
  # tightening it.
  validates :email, presence: true, uniqueness: true,
                    format: { with: /\A([^@\s]+)@((?:[-a-z0-9]+\.)+[a-z]{2,})\Z/i }
  validates :nickname, presence: true, uniqueness: true
  validates :password, length: { minimum: 4 }, confirmation: true, if: :password_required?

  # merb-auth's SaltedUser mixin (vendor/merb-auth/.../ar_salted_user.rb:10)
  # also required password_confirmation itself, not just that it match when
  # present. Rails' confirmation validator returns early on a nil
  # confirmation, so without this a signup that omits the confirmation
  # parameter entirely would validate.
  validates :password_confirmation, presence: true, if: :password_required?

  def member_of_any_team?
    !! team
  end

  def captain?
    member_of_any_team? && team.captain.id == id
  end

  def author_of?(game)
    game.author.id == self.id
  end

  def password_required?
    crypted_password.blank? || password.present?
  end
end
