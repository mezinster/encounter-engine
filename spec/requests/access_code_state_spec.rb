require "rails_helper"

describe "revoking and expiring access codes", type: :request do
  let(:game)     { create_game(:is_draft => false, :access_mode => "pass_required") }
  let(:operator) { u = create_user; u.update!(:is_operator => true); u }

  def sign_in(user)
    put login_path, :params => { :email => user.email, :password => "1234" }
  end

  def batch_of(n)
    key, raws = AccessCode.generate_batch!(:game => game, :count => n, :issued_by => operator)
    [ key, raws ]
  end

  it "refuses an ordinary signed-in user" do
    key, _ = batch_of(1)
    sign_in(create_user)

    patch revoke_game_access_codes_path(game), :params => { :batch_key => key }

    expect(response).to have_http_status(:unauthorized)
    expect(AccessCode.first.revoked_at).to be_nil
  end

  it "revokes a single code" do
    _key, raws = batch_of(2)
    code = AccessCode.find_by_code(raws.first)
    sign_in(operator)

    patch revoke_game_access_codes_path(game), :params => { :code_id => code.id }

    expect(code.reload.revoked_at).to be_present
    expect(AccessCode.where(:revoked_at => nil).count).to eq(1)
  end

  it "revokes a whole batch" do
    key, _ = batch_of(3)
    sign_in(operator)

    patch revoke_game_access_codes_path(game), :params => { :batch_key => key }

    expect(AccessCode.where.not(:revoked_at => nil).count).to eq(3)
  end

  it "lifts a revocation" do
    key, _ = batch_of(2)
    sign_in(operator)
    patch revoke_game_access_codes_path(game), :params => { :batch_key => key }

    patch unrevoke_game_access_codes_path(game), :params => { :batch_key => key }

    expect(AccessCode.where(:revoked_at => nil).count).to eq(2)
  end

  # F2: unrevoke and expiry already accepted code_id through targeted_codes,
  # but nothing exercised that -- only the view was missing a way to send one.
  it "lifts a revocation on a single code, leaving the rest of its batch revoked" do
    key, raws = batch_of(2)
    sign_in(operator)
    patch revoke_game_access_codes_path(game), :params => { :batch_key => key }
    code_a = AccessCode.find_by_code(raws.first)
    code_b = AccessCode.find_by_code(raws.last)

    patch unrevoke_game_access_codes_path(game), :params => { :code_id => code_a.id }

    expect(code_a.reload.revoked_at).to be_nil
    expect(code_b.reload.revoked_at).to be_present
  end

  it "sets an expiry on a batch" do
    key, _ = batch_of(2)
    sign_in(operator)

    patch expiry_game_access_codes_path(game), :params => { :batch_key => key, :expires_at => "2030-01-01" }

    expect(AccessCode.where.not(:expires_at => nil).count).to eq(2)
  end

  it "sets an expiry on a single code, leaving the rest of its batch untouched" do
    _key, raws = batch_of(2)
    code_a = AccessCode.find_by_code(raws.first)
    code_b = AccessCode.find_by_code(raws.last)
    sign_in(operator)

    patch expiry_game_access_codes_path(game), :params => { :code_id => code_a.id, :expires_at => "2030-01-01" }

    expect(code_a.reload.expires_at).to be_present
    expect(code_b.reload.expires_at).to be_nil
  end

  it "clears an expiry when given a blank date" do
    key, _ = batch_of(2)
    sign_in(operator)
    patch expiry_game_access_codes_path(game), :params => { :batch_key => key, :expires_at => "2030-01-01" }

    patch expiry_game_access_codes_path(game), :params => { :batch_key => key, :expires_at => "" }

    expect(AccessCode.where(:expires_at => nil).count).to eq(2)
  end

  # C10: these columns govern whether a code can still be EXCHANGED. A
  # redeemed code has already produced a pass, and that pass's life is not the
  # code's business -- expiring it must not reach through and end a run.
  it "leaves a redeemed code's pass untouched when the batch is revoked" do
    key, raws = batch_of(2)
    code = AccessCode.find_by_code(raws.first)
    pass = create_access_pass(:game => game)
    code.update!(:redeemed_at => Time.now, :access_pass_id => pass.id)
    sign_in(operator)

    patch revoke_game_access_codes_path(game), :params => { :batch_key => key }

    expect(pass.reload.revoked_at).to be_nil
    expect(code.reload.redeemed_at).to be_present
    expect(code.reload.revoked_at).to be_nil
    expect(code.state).to eq(:redeemed)
  end

  it "cannot reach another game's codes" do
    other = create_game(:is_draft => false, :access_mode => "pass_required")
    key, _ = AccessCode.generate_batch!(:game => other, :count => 1, :issued_by => operator)
    sign_in(operator)

    patch revoke_game_access_codes_path(game), :params => { :batch_key => key }

    expect(AccessCode.first.revoked_at).to be_nil
  end

  it "records an audit entry naming the batch" do
    key, _ = batch_of(2)
    sign_in(operator)

    expect { patch revoke_game_access_codes_path(game), :params => { :batch_key => key } }
      .to change { AdminAction.count }.by(1)
    expect(AdminAction.newest_first.first.action).to eq("revoke_access_codes")
  end

  # A no-op is not an administrative act worth recording -- AdminAudit's own
  # rule is that a refused/no-effect action leaves no entry.
  it "records no audit entry when a batch_key matches nothing" do
    sign_in(operator)

    expect { patch revoke_game_access_codes_path(game), :params => { :batch_key => "nonexistent" } }
      .not_to change { AdminAction.count }
  end
end
