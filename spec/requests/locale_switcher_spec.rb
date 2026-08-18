require "rails_helper"

# The header's language switcher builds every link from request.path plus
# ?locale=, which is right for a page reached by GET and wrong for a page
# RENDERED from a POST or PATCH: that path may have no GET route at all
# (ActionController::RoutingError), and where it does, following it silently
# throws the rendered page away. See app/views/layouts/_header.html.erb.
describe "the language switcher", type: :request do
  def sign_in(user)
    put login_path, :params => { :email => user.email, :password => "1234" }
  end

  def switcher_links(body)
    body.scan(/<a class="locale-switcher-link" href="([^"]+)"/).flatten
  end

  it "links to the current page on an ordinary GET" do
    get root_path

    expect(switcher_links(response.body)).to include("/?locale=en")
  end

  it "offers no links on a page rendered from a non-GET request" do
    post login_path, :params => { :email => "nobody@example.com", :password => "wrong" }

    expect(response.status).to eq(422)
    expect(switcher_links(response.body)).to be_empty
  end

  it "still names every language on a page rendered from a non-GET request" do
    post login_path, :params => { :email => "nobody@example.com", :password => "wrong" }

    I18n.available_locales.each do |locale|
      expect(response.body).to include(I18n.t("locales.#{locale}", :locale => :ru))
    end
  end

  # The code console is the page this came from: /games/:id/access_codes/lookup
  # is POST-only on purpose (a GET would put the customer's secret in the query
  # string), so a switcher link there was a guaranteed 404.
  it "offers no links on the access-code lookup result" do
    game     = create_game(:is_draft => false, :access_mode => "pass_required")
    operator = create_user
    operator.update!(:is_operator => true)
    _key, raws = AccessCode.generate_batch!(:game => game, :count => 1, :issued_by => operator)
    sign_in(operator)

    post lookup_game_access_codes_path(game), :params => { :access_code => raws.first }

    expect(response).to have_http_status(:ok)
    expect(switcher_links(response.body)).to be_empty
  end

  # The minted codes are shown exactly once and are unrecoverable afterwards;
  # a link that navigates away from them is worse than a broken one.
  it "offers no links on the page that shows freshly minted codes" do
    game     = create_game(:is_draft => false, :access_mode => "pass_required")
    operator = create_user
    operator.update!(:is_operator => true)
    sign_in(operator)

    post game_access_codes_path(game), :params => { :count => 2 }

    expect(response.body).to include("codes")
    expect(switcher_links(response.body)).to be_empty
  end
end

describe "a language chosen from the switcher", type: :request do
  def sign_in(user)
    put login_path, :params => { :email => user.email, :password => "1234" }
  end

  it "survives the next request, which carries no locale parameter" do
    get root_path, :params => { :locale => "en" }
    get root_path

    expect(response.body).to include(I18n.t("layout.header.home", :locale => :en))
  end

  it "is dropped when the profile form saves a preference" do
    user = create_user
    user.update!(:locale => "uk")
    sign_in(user)
    get dashboard_path, :params => { :locale => "en" }

    put user_path(user), :params => { :user => { :nickname => user.nickname } }
    get dashboard_path

    expect(response.body).to include(I18n.t("layout.header.dashboard", :locale => :uk))
    expect(response.body).not_to include(I18n.t("layout.header.dashboard", :locale => :en))
  end
end
