require "rails_helper"

describe "the UI shell", type: :request do
  it "boots with a resolved theme and links the token stylesheet" do
    get login_path

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("/stylesheets/tokens.css")
    # The boot script must run before first paint, inline in <head>, or the
    # page flashes the wrong theme on every load.
    expect(response.body).to include("/javascripts/theme.js")
  end

  it "offers a theme toggle" do
    get login_path

    expect(response.body).to include('id="theme-toggle"')
  end
end
