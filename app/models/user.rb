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

  # "Already has a password" now means either column is populated:
  # crypted_password for a row nobody has logged into since the bcrypt
  # migration, password_digest for a new or already-upgraded row. Checking
  # crypted_password alone broke the moment encrypt_password (below) stopped
  # writing it -- every user created or upgraded after that point has a
  # permanently blank crypted_password, so this predicate was permanently
  # true, forcing the presence/length/confirmation password validations onto
  # every unrelated save (a timezone change, a superadmin grant) and making
  # the record invalid whenever the request didn't also submit a password.
  def password_required?
    (crypted_password.blank? && password_digest.blank?) || password.present?
  end

  before_save :encrypt_password, if: -> { password.present? }

  # Rotated whenever the password changes, and compared in
  # Authentication#current_user. CookieStore keeps no server-side session
  # record, so this column is the only thing that can invalidate a cookie held
  # by someone else -- reset_session rotates the requesting browser only.
  #
  # Deliberately keyed on crypted_password_changed?/password_digest_changed?,
  # not password.present?. `password` is a plain attr_accessor (line 15): it
  # is never cleared after save, so on an AR instance that was ever assigned
  # a password (e.g. the one `create_user` returns), every later unrelated
  # #update/#save would see password.present? still true and re-rotate the
  # token -- silently invalidating a session that was just established, with
  # no password change involved. The two *_changed? predicates only fire when
  # encrypt_password (the callback above) actually produced a new hash, i.e.
  # a genuine password change; re-saving the same password onto the same
  # salt/digest is idempotent and correctly does not rotate. Order matters:
  # this must run after encrypt_password, which it does since before_save
  # callbacks run in definition order.
  #
  # Both columns are checked because encrypt_password (below) now writes
  # password_digest for every save that goes through it, while
  # crypted_password is retained only as the legacy verification path -- see
  # the comment there. Checking only crypted_password_changed? would silently
  # stop rotating the session on every real password change once encrypt_password
  # stopped touching that column, which is exactly the regression
  # session_eviction_spec.rb exists to catch. The lazy legacy-row upgrade in
  # #authenticate below writes password_digest via update_column, which
  # bypasses callbacks entirely (including this one) by design -- upgrading
  # the on-disk hash format for an already-authenticated request is not a
  # credential change and must not evict the session that is mid-request.
  before_save :rotate_session_token, if: -> { crypted_password_changed? || password_digest_changed? }
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

  # Verification order: bcrypt if this row has been upgraded, legacy SHA-1
  # otherwise. A successful legacy verification upgrades the row in place --
  # that is the only moment the plaintext is available, so it is the only
  # moment an upgrade is possible. A failed attempt upgrades nothing.
  def authenticate(candidate)
    if password_digest.present?
      return BCrypt::Password.new(password_digest).is_password?(candidate)
    end

    # Guard salt as well as crypted_password: a row with a null/blank salt
    # would otherwise hash "----#{candidate}--" (salt interpolated as "")
    # and could authenticate against it. Any row missing either half of the
    # pair is malformed and must fail closed, not verify.
    return false if crypted_password.blank? || salt.blank?
    return false unless self.class.encrypt(candidate, salt) == crypted_password

    update_column(:password_digest, BCrypt::Password.create(candidate))
    true
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

  # New passwords are bcrypt. self.encrypt above is retained unchanged for
  # verifying rows written by the Merb app -- see the comment on it; the
  # formula was verified byte-for-byte against real (salt, crypted_password)
  # pairs and changing it silently locks those users out, because a mismatched
  # hash raises nothing and the login form just rejects a correct password.
  #
  # Note self.salt ||= SecureRandom.hex(20) (formerly here) is no longer
  # reached for new passwords, which also resolves the related defect that a
  # user changing their password kept a legacy salt derived from a
  # one-second-resolution timestamp -- see the RULING in
  # .superpowers/sdd/2026-08-04-merb-to-rails-i18n/task-6-password-vectors.txt,
  # which no longer applies to any password set through this callback.
  #
  # Guarded to be a no-op when `password` already matches the stored digest.
  # `password` is a sticky attr_accessor (line 15, never cleared after save --
  # see the comment on rotate_session_token above) and this callback is
  # `before_save ... if: -> { password.present? }` (unconditional on whether
  # the value actually changed), so *every* later save of an AR instance that
  # was ever assigned a password -- e.g. `let(:user) { create_user }` reused
  # for an unrelated `user.update!(:timezone => ...)` -- re-runs this method.
  # SHA-1-with-a-stored-salt was deterministic, so a legacy re-hash of the
  # same password produced byte-identical output and crypted_password_changed?
  # stayed false. BCrypt::Password.create salts every call, so re-hashing an
  # unchanged password produces a *different* digest string every time --
  # marking password_digest dirty, rotating the session token, and evicting
  # the very session that just made the request. Checking the plaintext
  # against the existing digest first restores the old idempotence: a genuine
  # change (digest doesn't verify) still re-hashes and rotates; a re-save of
  # the same password does neither.
  def encrypt_password
    return if password_digest.present? && BCrypt::Password.new(password_digest).is_password?(password)

    self.password_digest = BCrypt::Password.create(password)
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
