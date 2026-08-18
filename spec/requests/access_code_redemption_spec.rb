require "rails_helper"

describe "redeeming an access code", type: :request do
  let(:game)    { create_game(:is_draft => false, :access_mode => "pass_required") }
  let(:captain) { create_user }
  let(:team)    { create_team(:captain => captain) }

  def sign_in(user)
    put login_path, :params => { :email => user.email, :password => "1234" }
  end

  def fresh_code
    _code, raw = create_access_code(:game => game)
    raw
  end

  it "creates a pass for the captain's team" do
    raw = fresh_code
    team
    sign_in(captain)

    expect { post redeem_access_code_path, :params => { :access_code => raw } }
      .to change { AccessPass.count }.by(1)

    pass = AccessPass.last
    expect(pass.team_id).to eq(team.id)
    expect(pass.game_id).to eq(game.id)
    expect(pass.source).to eq("access_code")
  end

  it "records what the code became" do
    raw = fresh_code
    team
    sign_in(captain)

    post redeem_access_code_path, :params => { :access_code => raw }

    code = AccessCode.find_by_code(raw)
    expect(code.redeemed_at).to be_present
    expect(code.access_pass_id).to eq(AccessPass.last.id)
  end

  it "accepts a code typed lowercase, with a dash, using confusables" do
    raw = fresh_code
    team
    sign_in(captain)
    typed = raw.dup.insert(5, "-").downcase.tr("01", "oi")

    expect { post redeem_access_code_path, :params => { :access_code => typed } }
      .to change { AccessPass.count }.by(1)
  end

  # C5: the code binds a purchase to one team, so the person who speaks for
  # the team is the one who may spend it.
  it "refuses a team member who is not the captain" do
    raw = fresh_code
    member = create_user
    team.members << member
    sign_in(member)

    expect { post redeem_access_code_path, :params => { :access_code => raw } }
      .not_to change { AccessPass.count }
  end

  it "refuses an anonymous visitor" do
    raw = fresh_code
    expect { post redeem_access_code_path, :params => { :access_code => raw } }
      .not_to change { AccessPass.count }
  end

  # Spec §5: a customer may well buy a code before forming a team. Sending
  # them to a 401 would be a dead end; they are sent to create one, and the
  # code is kept so they do not have to retype it off the card.
  it "sends a teamless user to create a team, keeping the code" do
    raw = fresh_code
    loner = create_user
    sign_in(loner)

    post redeem_access_code_path, :params => { :access_code => raw }

    expect(response).to redirect_to(new_team_path)
    expect(AccessPass.count).to eq(0)

    # And the form pre-fills it once they have a team.
    team = create_team(:captain => loner)
    get redeem_access_code_path
    expect(response.body).to include(raw)
  end

  describe "refusals, each with its own message" do
    before { team; sign_in(captain) }

    it "reports an unknown code" do
      post redeem_access_code_path, :params => { :access_code => "ZZZZZZZZZZ" }
      expect(AccessPass.count).to eq(0)
      expect(flash[:alert]).to include("не найден")
    end

    it "reports an already-redeemed code" do
      raw = fresh_code
      AccessCode.find_by_code(raw).update!(:redeemed_at => Time.now)

      post redeem_access_code_path, :params => { :access_code => raw }
      expect(AccessPass.count).to eq(0)
      expect(flash[:alert]).to include("уже использован")
    end

    it "reports a revoked code" do
      raw = fresh_code
      AccessCode.find_by_code(raw).update!(:revoked_at => Time.now)

      post redeem_access_code_path, :params => { :access_code => raw }
      expect(AccessPass.count).to eq(0)
      expect(flash[:alert]).to include("отозван")
    end

    it "reports an expired code" do
      raw = fresh_code
      AccessCode.find_by_code(raw).update!(:expires_at => 1.minute.ago)

      post redeem_access_code_path, :params => { :access_code => raw }
      expect(AccessPass.count).to eq(0)
      expect(flash[:alert]).to include("истёк")
    end

    it "reports a game that is no longer available" do
      raw = fresh_code
      game.withdraw!

      post redeem_access_code_path, :params => { :access_code => raw }
      expect(AccessPass.count).to eq(0)
      expect(flash[:alert]).to include("недоступна")
    end
  end

  # C11: B6 lets a team hold several passes, consumed oldest-first.
  it "allows a second redemption while the team already holds a live pass" do
    first = fresh_code
    second = fresh_code
    team
    sign_in(captain)

    post redeem_access_code_path, :params => { :access_code => first }
    expect { post redeem_access_code_path, :params => { :access_code => second } }
      .to change { AccessPass.count }.by(1)
  end

  # C7: the claim is a conditional UPDATE, not a Ruby-side nil check. Exercise
  # the claim itself rather than simulating threads: a second claim against an
  # already-claimed row must affect zero rows and create nothing.
  it "cannot be claimed twice" do
    raw = fresh_code
    team
    sign_in(captain)
    post redeem_access_code_path, :params => { :access_code => raw }

    expect { post redeem_access_code_path, :params => { :access_code => raw } }
      .not_to change { AccessPass.count }
  end
end
