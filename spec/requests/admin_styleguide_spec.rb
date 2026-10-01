require "rails_helper"

describe "the styleguide", type: :request do
  let(:superadmin) do
    u = create_user
    u.update!(:is_superadmin => true)
    u
  end
  let(:ordinary) { create_user }

  def login_as(user)
    put login_path, :params => { :email => user.email, :password => "1234" }
  end

  it "refuses an ordinary user" do
    login_as(ordinary)
    get admin_styleguide_path

    expect(response).to have_http_status(:unauthorized)
  end

  it "refuses a signed-out visitor" do
    get admin_styleguide_path

    # A visitor with no session is redirected (302) to login rather than shown a 401.
    expect(response).to have_http_status(:found)
  end

  context "for a superadmin" do
    before do
      login_as(superadmin)
      get admin_styleguide_path
    end

    let(:doc) { Nokogiri::HTML(response.body) }

    it "renders" do
      expect(response).to have_http_status(:ok)
    end

    # The invalid specimens come from a real Game.valid?, so they are drawn by
    # the real field_error_proc -- not hand-copied markup that could drift.
    it "renders real invalid specimens" do
      expect(doc.at_css("input#game_name.is-invalid")).to be_present
      expect(doc.at_css("#game_name-error")).to be_present
      expect(doc.at_css("input#game_max_team_number[type=number][aria-invalid=true]")).to be_present
      expect(doc.at_css("input[type=radio][name='game[visibility]'][aria-invalid=true]")).to be_present
    end

    it "shows every button kind" do
      %w[btn--go btn--quiet btn--danger].each do |kind|
        expect(doc.at_css(".styleguide .btn.#{kind}")).to be_present, kind
      end
      expect(doc.at_css(".styleguide .btn[disabled]")).to be_present
    end

  end

  it "writes nothing to the database" do
    login_as(superadmin)

    expect { get admin_styleguide_path }.not_to change(Game, :count)
  end

  it "is linked from the admin dashboard" do
    login_as(superadmin)
    get admin_dashboard_path

    expect(response.body).to include(admin_styleguide_path)
  end
end
