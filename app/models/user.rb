# -*- encoding : utf-8 -*-
require "digest/sha1"

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

  # merb-auth's SaltedUser mixin (merb-auth-more/.../ar_salted_user.rb:10,
  # removed by Task 13; see git history) also required password_confirmation
  # itself, not just that it match when
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

  before_save :encrypt_password, if: -> { password.present? }

  # Digest::SHA1.hexdigest("--" + salt + "--" + password + "--") -- this is
  # merb-auth's SaltedUser#encrypt (merb-auth-more/lib/
  # merb-auth-more/mixins/salted_user.rb:53, removed by Task 13; see git
  # history), preserved byte-for-byte.
  # Existing crypted_password values were produced by this exact formula;
  # changing it silently locks out every current user, since a mismatched
  # hash raises no error -- the login form just rejects a correct password.
  # Verified against two real (salt, crypted_password) pairs captured from a
  # database written by the running Merb app -- see
  # spec/models/user/authenticate_spec.rb and
  # .superpowers/sdd/2026-08-04-merb-to-rails-i18n/task-6-password-vectors.txt.
  def self.encrypt(password, salt)
    Digest::SHA1.hexdigest("--#{salt}--#{password}--")
  end

  def authenticate(candidate)
    # Guard salt as well as crypted_password: a row with a null/blank salt
    # would otherwise hash "----#{candidate}--" (salt interpolated as "")
    # and could authenticate against it. Any row missing either half of the
    # pair is malformed and must fail closed, not verify.
    return false if crypted_password.blank? || salt.blank?

    self.class.encrypt(candidate, salt) == crypted_password
  end

  private

  def encrypt_password
    # merb-auth generated new salts as
    #   Digest::SHA1.hexdigest("--#{Time.now.to_s}--#{login_param}--")
    # (login_param is the constant :email). Time.now.to_s has one-second
    # resolution and login_param never varies, so that salt carries no
    # per-user entropy at all -- it's fully predictable from a timestamp.
    # The vectors file demonstrates this directly: two distinct demo
    # accounts created in the same second share one salt. RULING (see
    # task-6-password-vectors.txt): do NOT reproduce that formula for new
    # salts. Salts are stored per row, so existing users keep verifying
    # against whatever salt is already in their row -- only *new* salts
    # change here, to a cryptographically strong SecureRandom.hex(20).
    self.salt ||= SecureRandom.hex(20)
    self.crypted_password = self.class.encrypt(password, salt)
  end
end
