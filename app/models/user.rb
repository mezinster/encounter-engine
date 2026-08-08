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

  validate :last_superadmin_keeps_the_role

  # Handles are stored bare -- no leading "@", no host, no scheme -- so the
  # profile can render a working link, and two players who typed the same
  # handle differently are stored identically. Each key is a column; each
  # value is the hosts to strip for that column.
  CONTACT_HANDLE_HOSTS = {
    :instagram   => %w[instagram.com],
    :telegram_id => %w[t.me telegram.me]
  }.freeze

  before_validation :normalise_contact_handles

  def member_of_any_team?
    !! team
  end

  # Safe navigation on captain, not decoration: Team declares
  # `belongs_to :captain, optional: true`, captain_id is a nullable column and
  # nothing validates its presence, so a captain-less team is a state the model
  # permits -- even though TeamsController#create always sets one today.
  # `team.captain.id` raised NoMethodError on such a team, and this is called
  # from eight places including SecurityFilters#ensure_team_captain, which
  # gates quitting a game, requesting entry and inviting members. Those would
  # have 500'd rather than refused. A team with no captain has no captain, so
  # false is the right answer.
  def captain?
    member_of_any_team? && team.captain&.id == id
  end

  # game.author_id, not game.author.id -- the latter loads the author
  # association per call, and this is called once per game in games/_list.html.erb
  # with no preload, which was an N+1 on every logged-in author's listing
  # (spec/requests/games_listing_spec.rb, "issues the same number of queries...").
  # author_id is already on the loaded Game row, so this needs no query at all.
  def author_of?(game)
    game.author_id == self.id
  end

  def superadmin?
    self.is_superadmin
  end

  def self.superadmin_count
    where(:is_superadmin => true).count
  end

  # The instance must never end up with nobody able to administer it.
  def last_superadmin?
    self.superadmin? && User.superadmin_count <= 1
  end

  def password_required?
    crypted_password.blank? || password.present?
  end

  before_save :encrypt_password, if: -> { password.present? }

  # Rotated whenever the password changes, and compared in
  # Authentication#current_user. CookieStore keeps no server-side session
  # record, so this column is the only thing that can invalidate a cookie held
  # by someone else -- reset_session rotates the requesting browser only.
  #
  # Deliberately keyed on crypted_password_changed?, not password.present?.
  # `password` is a plain attr_accessor (line 15): it is never cleared after
  # save, so on an AR instance that was ever assigned a password (e.g. the one
  # `create_user` returns), every later unrelated #update/#save would see
  # password.present? still true and re-rotate the token -- silently
  # invalidating a session that was just established, with no password change
  # involved. crypted_password_changed? only fires when encrypt_password (the
  # callback above) actually produced a new hash, i.e. a genuine password
  # change; re-saving the same password onto the same salt is idempotent and
  # correctly does not rotate. Order matters: this must run after
  # encrypt_password, which it does since before_save callbacks run in
  # definition order.
  before_save :rotate_session_token, if: -> { crypted_password_changed? }
  before_create :ensure_session_token

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

  # The instance must never end up with nobody able to
  # administer it. Enforced here rather than only in the
  # controller because the controller path cannot actually
  # be reached: require_superadmin! means the actor holds
  # the role, so if the target is the LAST superadmin the
  # target is the actor, and the self-revoke guard fires
  # first. A console mistake is the real risk.
  def last_superadmin_keeps_the_role
    return unless is_superadmin_changed?(:from => true, :to => false)
    return if User.superadmin_count > 1

    errors.add(:is_superadmin,
               I18n.t("admin.users.cannot_revoke_last"))
  end

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

  def rotate_session_token
    self.session_token = SecureRandom.hex(20)
  end

  def ensure_session_token
    self.session_token ||= SecureRandom.hex(20)
  end

  # Order matters: scheme, then "www.", then the host, then a leading "@",
  # then a trailing slash. Stripping "@" first would leave "@" embedded in a
  # pasted URL untouched.
  def normalise_contact_handles
    CONTACT_HANDLE_HOSTS.each do |field, hosts|
      value = self[field].to_s.strip

      value = value.sub(%r{\Ahttps?://}i, "")
      value = value.sub(%r{\Awww\.}i, "")
      hosts.each { |host| value = value.sub(%r{\A#{Regexp.escape(host)}/}i, "") }
      value = value.sub(/\A@/, "")
      value = value.sub(%r{/\z}, "")

      # presence, not the raw value: an emptied field must land as NULL so the
      # views can test presence to decide whether to render a row at all.
      self[field] = value.presence
    end
  end
end
