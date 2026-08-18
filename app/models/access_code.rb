# -*- encoding : utf-8 -*-
# A secret which, exchanged once, creates exactly one AccessPass.
#
# The code is NOT the entitlement. An unredeemed code belongs to nobody, which
# is what keeps access_passes.team_id NOT NULL -- see the access-gated-games
# design, B4. Redemption is what mints a pass.
class AccessCode < ApplicationRecord
  # Crockford base32: the digits and the uppercase letters, excluding I, L, O
  # and U. Thirty-two symbols, so a ten-character code carries 2^50.
  ALPHABET = "0123456789ABCDEFGHJKMNPQRSTVWXYZ".freeze
  LENGTH   = 10

  belongs_to :game
  belongs_to :issued_by,   :class_name => "User",       :optional => true
  belongs_to :access_pass, :optional => true

  validates :code_digest, :presence => true, :uniqueness => true
  validates :batch_key,   :presence => true
  validate  :game_is_gated, :on => :create

  scope :of_batch, ->(key) { where(:batch_key => key) }

  # One method, used by generation, redemption AND the operator's lookup. If
  # the lookup and the redemption path ever disagreed here, an operator would
  # confirm a code is fine while the customer keeps failing to redeem it.
  #
  # The confusable mapping is the whole point of the alphabet: Crockford
  # excludes I, L, O and U from the OUTPUT so they can be accepted as INPUT
  # aliases for 1, 1, 0 and V. A customer types what they see on the card.
  def self.normalize(raw)
    raw.to_s.upcase.gsub(/[\s\-]/, "").tr("ILOU", "110V")
  end

  def self.digest(raw)
    Digest::SHA256.hexdigest(normalize(raw))
  end

  # Mirrors User.find_by_reset_token's three guards: a blank input resolves to
  # nothing even against a blank stored digest, and the comparison is
  # constant-time rather than trusting the database's indexed equality.
  def self.find_by_code(raw)
    return nil if raw.to_s.strip.empty?

    wanted = digest(raw)
    candidate = where.not(:code_digest => nil).find_by(:code_digest => wanted)
    return nil unless candidate
    return nil unless ActiveSupport::SecurityUtils.secure_compare(candidate.code_digest, wanted)

    candidate
  end

  # Returns [batch_key, raw_codes]. The raw codes are the ONLY copy: they are
  # rendered once by the caller and never persisted.
  #
  # SecureRandom.random_number(ALPHABET.length) per character rather than
  # slicing a longer random string: 32 divides the generator's range exactly,
  # so the draw is uniform. Taking characters modulo an alphabet that does not
  # divide evenly is the standard way to quietly lose entropy.
  def self.generate_batch!(game:, count:, issued_by:, expires_at: nil)
    key  = SecureRandom.hex(6)
    raws = []

    transaction do
      count.times do
        raw = Array.new(LENGTH) { ALPHABET[SecureRandom.random_number(ALPHABET.length)] }.join
        create!(:game => game, :code_digest => digest(raw), :batch_key => key,
                :issued_by => issued_by, :expires_at => expires_at)
        raws << raw
      end
    end

    [ key, raws ]
  end

  def redeemable?
    revoked_at.nil? && redeemed_at.nil? && (expires_at.nil? || expires_at > Time.now)
  end

  # Claims this code for a pass, or returns false if another request got there
  # first. THE precondition lives in the WHERE, not in Ruby: two requests can
  # both read redeemed_at as nil and both mint a pass, and that failure is
  # silent -- a free run, and two passes pointing at one purchase with nothing
  # in the data to say which was the mistake.
  #
  # Returns true when this call took the row.
  def claim!(pass)
    taken = self.class.where(:id => id, :redeemed_at => nil)
                      .update_all(:redeemed_at => Time.now, :access_pass_id => pass.id,
                                  :updated_at => Time.now)
    taken == 1
  end

  # Redeemed wins over expired: a redeemed code has already produced a pass,
  # and that pass's life is not the code's business. See the design, C10.
  def state
    return :redeemed if redeemed_at.present?
    return :revoked  if revoked_at.present?
    return :expired  if expires_at.present? && expires_at <= Time.now

    :outstanding
  end

  private

  def game_is_gated
    return if game&.pass_required?

    errors.add(:game, :not_gated)
  end
end
