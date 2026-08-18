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

  def index
    @batches = @game.access_codes.order(:created_at)
  end

  def create
    count = params[:count].to_i

    unless count.between?(1, MAX_PER_BATCH)
      redirect_to game_access_codes_path(@game),
                  :alert => t("access_codes.bad_count", :max => MAX_PER_BATCH) and return
    end

    key, @codes = AccessCode.generate_batch!(
      :game => @game, :count => count, :issued_by => current_user,
      :expires_at => params[:expires_at].presence
    )

    # The batch_key, never a code: batch_key is a handle that grants nothing.
    record_admin_action("generate_access_codes", @game, "#{key} (#{count})")
    @batch_key = key
    render :created
  end

  # Revocation and expiry govern whether a code can still be EXCHANGED, and
  # nothing else. Neither reaches a code that has already been redeemed: that
  # code has produced an AccessPass, and ending a run the customer paid for is
  # a separate, deliberate act through the pass. See the design, C10.
  def revoke
    n = targeted_codes.update_all(:revoked_at => Time.now, :updated_at => Time.now)
    record_admin_action("revoke_access_codes", @game, target_label(n))
    redirect_to game_access_codes_path(@game), :notice => t("access_codes.revoked_notice", :count => n)
  end

  def unrevoke
    n = targeted_codes.update_all(:revoked_at => nil, :updated_at => Time.now)
    record_admin_action("unrevoke_access_codes", @game, target_label(n))
    redirect_to game_access_codes_path(@game), :notice => t("access_codes.unrevoked_notice", :count => n)
  end

  def expiry
    when_ = params[:expires_at].presence
    n = targeted_codes.update_all(:expires_at => when_, :updated_at => Time.now)
    record_admin_action("set_access_code_expiry", @game, "#{target_label(n)} -> #{when_ || "-"}")
    redirect_to game_access_codes_path(@game), :notice => t("access_codes.expiry_notice", :count => n)
  end

  private

  # ONE definition of "which codes is this operator acting on", used by all
  # three actions. Always scoped through @game, so a batch_key or id belonging
  # to another game resolves to nothing rather than to somebody else's codes.
  def targeted_codes
    scope = @game.access_codes
    return scope.where(:id => params[:code_id]) if params[:code_id].present?

    scope.of_batch(params[:batch_key].to_s)
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
