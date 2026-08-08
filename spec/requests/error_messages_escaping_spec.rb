# -*- encoding : utf-8 -*-
require "rails_helper"

# ApplicationHelper#error_messages_for (app/helpers/application_helper.rb)
# builds its markup from errors.full_messages and returns it html_safe
# without escaping. A prior security review cleared this on the reasoning
# that no validation message interpolates a user-supplied *value* -- only
# %{attribute}, a humanised column name. That reasoning missed
# Game#available_locales_are_known (app/models/game.rb), whose
# %{locales} is `unknown.join(", ")` -- built straight from
# params[:game][:available_locale_list], which GamesController permits as
# arbitrary strings (see game_params). Submit a script payload as one of
# those locales and it survives verbatim into the rendered response.
describe "error message escaping", type: :request do
  let(:author) { create_user }
  let(:game)   { create_game(:author => author, :is_draft => true) }

  def sign_in(user)
    put login_path, :params => { :email => user.email, :password => "1234" }
  end

  it "escapes an unknown-locale value injected into the validation message" do
    sign_in(author)

    payload = "<img src=x onerror=alert(1)>"

    patch game_path(game), :params => {
      :game => { :available_locale_list => [payload] }
    }

    expect(response.body).not_to include(payload)
    expect(response.body).to include(ERB::Util.html_escape(payload))
  end
end
