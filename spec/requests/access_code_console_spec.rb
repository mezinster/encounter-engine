require "rails_helper"

describe "the access-code console", type: :request do
  let(:game)     { create_game(:is_draft => false, :access_mode => "pass_required") }
  let(:operator) { u = create_user; u.update!(:is_operator => true); u }

  def sign_in(user)
    put login_path, :params => { :email => user.email, :password => "1234" }
  end

  it "refuses an ordinary signed-in user" do
    sign_in(create_user)
    get game_access_codes_path(game)
    expect(response).to have_http_status(:unauthorized)
  end

  it "lists a batch with its counts and never shows a code" do
    key, raws = AccessCode.generate_batch!(:game => game, :count => 3, :issued_by => operator)
    AccessCode.find_by_code(raws.first).update!(:revoked_at => Time.now)
    sign_in(operator)

    get game_access_codes_path(game)

    expect(response.body).to include(key)
    expect(response.body).not_to include(raws.first)
    expect(response.body).not_to include(raws.last)
  end

  # The whole reason the lookup exists: digest-only storage leaves no other
  # way for an operator to answer "my code does not work".
  it "resolves a code the operator cannot see" do
    _key, raws = AccessCode.generate_batch!(:game => game, :count => 1, :issued_by => operator)
    sign_in(operator)

    post lookup_game_access_codes_path(game), :params => { :access_code => raws.first }

    expect(response).to have_http_status(:ok)
    expect(response.body).to include(AccessCode.first.batch_key)
  end

  it "resolves a code typed with confusables and a dash" do
    _key, raws = AccessCode.generate_batch!(:game => game, :count => 1, :issued_by => operator)
    typed = raws.first.dup.insert(5, "-").downcase.tr("01", "oi")
    sign_in(operator)

    post lookup_game_access_codes_path(game), :params => { :access_code => typed }

    expect(response.body).to include(AccessCode.first.batch_key)
  end

  it "reports an unknown code without raising" do
    sign_in(operator)

    post lookup_game_access_codes_path(game), :params => { :access_code => "ZZZZZZZZZZ" }

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("не найден")
  end

  it "does not resolve another game's code" do
    other = create_game(:is_draft => false, :access_mode => "pass_required")
    _key, raws = AccessCode.generate_batch!(:game => other, :count => 1, :issued_by => operator)
    sign_in(operator)

    post lookup_game_access_codes_path(game), :params => { :access_code => raws.first }

    expect(response.body).to include("не найден")
  end

  it "shows which team a redeemed code became" do
    _key, raws = AccessCode.generate_batch!(:game => game, :count => 1, :issued_by => operator)
    pass = create_access_pass(:game => game)
    AccessCode.first.update!(:redeemed_at => Time.now, :access_pass_id => pass.id)
    sign_in(operator)

    post lookup_game_access_codes_path(game), :params => { :access_code => raws.first }

    expect(response.body).to include(pass.team.name)
  end

  # Sub-project B broke two query-count specs by adding a per-row read behind
  # a listing. The batch summary must be ONE grouped query, not one per batch.
  it "keeps the query count flat as the number of batches grows" do
    sign_in(operator)
    2.times { AccessCode.generate_batch!(:game => game, :count => 2, :issued_by => operator) }
    small = count_queries { get game_access_codes_path(game) }

    6.times { AccessCode.generate_batch!(:game => game, :count => 2, :issued_by => operator) }
    large = count_queries { get game_access_codes_path(game) }

    expect(large).to eq(small)
  end
end
