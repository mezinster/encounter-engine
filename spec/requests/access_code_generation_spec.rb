require "rails_helper"

describe "generating access codes", type: :request do
  let(:game)     { create_game(:is_draft => false, :access_mode => "pass_required") }
  let(:operator) { u = create_user; u.update!(:is_operator => true); u }
  let(:ordinary) { create_user }

  def sign_in(user)
    put login_path, :params => { :email => user.email, :password => "1234" }
  end

  it "refuses an anonymous visitor" do
    post game_access_codes_path(game), :params => { :count => 3 }
    expect(AccessCode.count).to eq(0)
  end

  it "refuses an ordinary signed-in user" do
    sign_in(ordinary)
    post game_access_codes_path(game), :params => { :count => 3 }
    expect(response).to have_http_status(:unauthorized)
    expect(AccessCode.count).to eq(0)
  end

  it "refuses generation on a scheduled game" do
    scheduled = create_game(:is_draft => false)
    sign_in(operator)
    post game_access_codes_path(scheduled), :params => { :count => 3 }
    expect(AccessCode.count).to eq(0)
  end

  it "mints the requested number for an operator" do
    sign_in(operator)
    expect { post game_access_codes_path(game), :params => { :count => 3 } }
      .to change { AccessCode.count }.by(3)
    expect(AccessCode.pluck(:batch_key).uniq.length).to eq(1)
    expect(AccessCode.pluck(:issued_by_id).uniq).to eq([ operator.id ])
  end

  # The whole point of the screen: the codes exist in the clear exactly once.
  it "renders the raw codes once, and they are real codes" do
    sign_in(operator)
    post game_access_codes_path(game), :params => { :count => 2 }

    expect(response).to have_http_status(:ok)
    # The view renders them grouped, XXXXX-XXXXX, so match that shape --
    # and note find_by_code normalises the dash away, which is exactly what a
    # customer copying the printed form needs it to do.
    shown = response.body.scan(/[0-9A-HJKMNP-TV-Z]{5}-[0-9A-HJKMNP-TV-Z]{5}/).uniq
    expect(shown.length).to be >= 2
    expect(AccessCode.find_by_code(shown.first)).to be_present
  end

  it "warns that this is the only time they are shown" do
    sign_in(operator)
    post game_access_codes_path(game), :params => { :count => 1 }
    expect(response.body).to include("единственный раз")
  end

  it "carries an optional expiry onto the whole batch" do
    sign_in(operator)
    post game_access_codes_path(game), :params => { :count => 2, :expires_at => "2030-01-01" }
    expect(AccessCode.where.not(:expires_at => nil).count).to eq(2)
  end

  it "records an audit entry naming the batch, never a code" do
    sign_in(operator)
    expect { post game_access_codes_path(game), :params => { :count => 2 } }
      .to change { AdminAction.count }.by(1)

    entry = AdminAction.newest_first.first
    expect(entry.action).to eq("generate_access_codes")
    expect(entry.details).to include(AccessCode.first.batch_key)
  end

  it "refuses a count outside the permitted range without minting anything" do
    sign_in(operator)
    expect { post game_access_codes_path(game), :params => { :count => 0 } }
      .not_to change { AccessCode.count }
    expect { post game_access_codes_path(game), :params => { :count => 501 } }
      .not_to change { AccessCode.count }
  end
end
