require "rails_helper"

describe "the manual", type: :request do
  it "serves the Russian manual to a signed-out visitor" do
    get manual_path

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("Руководство пользователя")
  end

  it "serves the English manual when the locale is en" do
    get manual_path(:locale => :en)

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("User manual")
  end

  it "renders the markdown rather than echoing it" do
    get manual_path

    expect(response.body).to include("<table>")
    expect(response.body).not_to include("|---|")
  end

  # The literal Polish, not I18n.t: an assertion written as
  # include(I18n.t(key)) resolves the same way the view does and therefore
  # cannot fail on a missing or wrong key.
  it "tells a Polish reader that this is the Russian version" do
    get manual_path(:locale => :pl)

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("Podręcznik nie został jeszcze przetłumaczony")
    expect(response.body).to include("Руководство пользователя")
  end

  it "shows no fallback note when the manual is in the reader's language" do
    get manual_path(:locale => :en)

    expect(response.body).not_to include("not yet available in your language")
  end

  it "is linked from the left menu signed out" do
    get root_path

    expect(response.body).to include(%(href="/manual"))
  end

  it "is linked from the left menu signed in" do
    user = create_user
    put login_path, :params => { :email => user.email, :password => "1234" }

    get dashboard_path

    expect(response.body).to include(%(href="/manual"))
  end
end
