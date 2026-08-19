# -*- encoding : utf-8 -*-
# The operator's code console: mint codes, and (in later tasks) revoke, expire
# and look them up.
#
# Only the digest is stored, so this screen can never display an existing
# code. #create is the one moment the raw values exist, and they are rendered
# straight into the response and dropped.
class AccessCodesController < ApplicationController
  include AdminAudit

  # A batch is a print run, not a bulk import. The ceiling is a guard against
  # a mistyped count minting tens of thousands of rows in one request, not a
  # business rule.
  MAX_PER_BATCH = 500

  before_action :require_authentication!
  before_action :find_game
  before_action :ensure_commercial_operator
  before_action :ensure_game_is_gated

  # Batches, not codes -- there is nothing readable to show per code, and the
  # counts are what an operator actually asks for.
  #
  # SEVEN queries for the whole page regardless of how many batches exist, not
  # one lookup per batch: sub-project B broke two query-count specs by adding
  # a per-row read behind a listing, and this screen has its own. Six are
  # grouped (batches, sizes, redeemed, revoked, expired, issuer id per batch);
  # the seventh is one flat User lookup for the issuers' nicknames, keyed off
  # the distinct ids the grouped query returned -- still one query, not one
  # per batch.
  def index
    scope = @game.access_codes
    @batches   = scope.group(:batch_key).minimum(:created_at)
    @sizes     = scope.group(:batch_key).count
    @redeemed  = scope.where.not(:redeemed_at => nil).group(:batch_key).count
    @revoked   = scope.where(:redeemed_at => nil).where.not(:revoked_at => nil).group(:batch_key).count
    @expired   = scope.where(:redeemed_at => nil, :revoked_at => nil)
                      .where("expires_at IS NOT NULL AND expires_at <= ?", Time.now)
                      .group(:batch_key).count
    @issuers      = scope.group(:batch_key).minimum(:issued_by_id)
    @issuer_names = User.where(:id => @issuers.values.compact.uniq).pluck(:id, :nickname).to_h
  end

  def create
    count = params[:count].to_i

    unless count.between?(1, MAX_PER_BATCH)
      redirect_to game_access_codes_path(@game),
                  :alert => t("access_codes.bad_count", :max => MAX_PER_BATCH) and return
    end

    ok, expires_at = parsed_expiry(params[:expires_at])
    unless ok
      redirect_to game_access_codes_path(@game),
                  :alert => t("access_codes.bad_expiry") and return
    end

    key, @codes = AccessCode.generate_batch!(
      :game => @game, :count => count, :issued_by => current_user,
      :expires_at => expires_at
    )

    # The batch_key, never a code: batch_key is a handle that grants nothing.
    record_admin_action("generate_access_codes", @game, "#{key} (#{count})")
    @batch_key = key

    # The one page that ever renders a raw code. Set here, not in the view --
    # a shared or intermediary cache must never be given the chance to retain
    # this response for a second viewer.
    response.headers["Cache-Control"] = "no-store"
    render :created
  end

  # Revocation and expiry govern whether a code can still be EXCHANGED, and
  # nothing else. Neither reaches a code that has already been redeemed: that
  # code has produced an AccessPass, and ending a run the customer paid for is
  # a separate, deliberate act through the pass. See the design, C10.
  #
  # This is enforced structurally in targeted_codes (redeemed_at => nil), not
  # merely by AccessCode#state's redeemed-wins-over-revoked precedence -- a
  # future reader who writes revoked_at/expires_at directly, without going
  # through #state, must not see a redeemed code reported as revoked.
  def revoke
    n = targeted_codes.update_all(:revoked_at => Time.now, :updated_at => Time.now)
    return nothing_matched if n.zero?

    record_admin_action("revoke_access_codes", @game, target_label(n))
    redirect_to game_access_codes_path(@game), :notice => t("access_codes.revoked_notice", :count => n)
  end

  def unrevoke
    n = targeted_codes.update_all(:revoked_at => nil, :updated_at => Time.now)
    return nothing_matched if n.zero?

    record_admin_action("unrevoke_access_codes", @game, target_label(n))
    redirect_to game_access_codes_path(@game), :notice => t("access_codes.unrevoked_notice", :count => n)
  end

  def expiry
    ok, when_ = parsed_expiry(params[:expires_at])
    unless ok
      redirect_to game_access_codes_path(@game),
                  :alert => t("access_codes.bad_expiry") and return
    end

    n = targeted_codes.update_all(:expires_at => when_, :updated_at => Time.now)
    return nothing_matched if n.zero?

    record_admin_action("set_access_code_expiry", @game, "#{target_label(n)} -> #{when_ || "-"}")
    redirect_to game_access_codes_path(@game), :notice => t("access_codes.expiry_notice", :count => n)
  end

  # An operator cannot read codes off this screen, so the only way to answer
  # "my code does not work" is for the customer to supply the secret and for
  # us to digest it exactly as redemption does. That is the whole support
  # workflow, and it is why AccessCode.normalize is one method rather than
  # two: if this and redemption ever disagreed about confusables, an operator
  # would confirm a code is fine while the customer kept failing to use it.
  def lookup
    code = AccessCode.find_by_code(params[:access_code])
    @found = code if code && code.game_id == @game.id
    index
    render :index
  end

  private

  # ONE definition of "which codes is this operator acting on", used by all
  # three actions. Always scoped through @game, so a batch_key or id belonging
  # to another game resolves to nothing rather than to somebody else's codes.
  # Excludes redeemed codes: those columns govern exchangeability only, and a
  # redeemed row must never be written by any of the three actions above.
  def targeted_codes
    scope = @game.access_codes.where(:redeemed_at => nil)
    return scope.where(:id => params[:code_id]) if params[:code_id].present?

    scope.of_batch(params[:batch_key].to_s)
  end

  # Blank ("", the date field cleared) means "clear the expiry" and is a
  # legitimate value to write. Present-but-unparseable ("not-a-date", or
  # anything Time.zone.parse rejects) is a DIFFERENT thing -- ActiveRecord's
  # own datetime type cast turns exactly that case into nil too, silently, so
  # letting it flow through to update_all/create! would clear the expiry
  # while expiry_notice told the operator it had been set. Parsing here,
  # before either write, is what tells the two cases apart: returns
  # [true, nil] for blank, [true, a Time] for something parseable, and
  # [false, nil] for present-but-garbage, which the caller must refuse rather
  # than write.
  def parsed_expiry(raw)
    return [ true, nil ] if raw.blank?

    parsed = begin
      Time.zone.parse(raw)
    rescue ArgumentError
      nil
    end
    return [ false, nil ] if parsed.nil?

    [ true, parsed ]
  end

  # A no-op is not an administrative act: AdminAudit's own rule is that a
  # refused/ineffective action leaves no entry, so nothing is recorded here.
  def nothing_matched
    redirect_to game_access_codes_path(@game), :alert => t("access_codes.nothing_matched")
  end

  # The batch key or the code's id -- never the code itself, which this
  # application does not hold and must never write to an audit entry.
  def target_label(count)
    params[:code_id].present? ? "code ##{params[:code_id]} (#{count})" : "#{params[:batch_key]} (#{count})"
  end

  def find_game
    @game = Game.find(params[:game_id])
  end

  def ensure_commercial_operator
    raise Authentication::Unauthorized, t("errors.must_operate_commercial") unless
      current_user.may_operate_commercial?
  end

  def ensure_game_is_gated
    raise Authentication::Unauthorized, t("errors.game_not_gated") unless @game.pass_required?
  end
end
