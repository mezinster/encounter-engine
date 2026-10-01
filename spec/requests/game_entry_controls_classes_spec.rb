require "rails_helper"

# shared/_game_entry_controls rendered bare button_to's; the home page reuses
# it, so it gained .btn classes. The dashboard renders it too: same text, now
# styled. Frozen Cucumber steps press these buttons by their text.
describe "the game-entry controls on the dashboard", type: :request do
  it "renders the apply button styled, with its text unchanged" do
    captain = create_user
    create_team(:captain => captain)
    game = create_game
    set_game_schedule!(game, :starts_at => 1.day.from_now)
    put login_path, :params => { :email => captain.email, :password => "1234" }

    get dashboard_path

    button = Nokogiri::HTML(response.body).css("button").find { |b| b.text.strip == "Подать заявку на регистрацию" }
    expect(button).to be_present
    expect(button["class"].split).to include("btn", "btn--go")
  end
end
