require "rails_helper"

# The four selectors below are load-bearing. Two are named inside frozen
# .feature files and cannot change at all; two are named in step definitions
# which are editable, but keeping them removes a class of risk for free.
describe "the DOM contract the acceptance suite depends on", type: :request do
  let(:author) { create_user }

  def sign_in(u)
    put login_path, :params => { :email => u.email, :password => "1234" }
  end

  it "keeps #locale-switcher in the header" do
    get login_path
    expect(response.body).to include('id="locale-switcher"')
  end

  it "keeps #coming and #mygames on the dashboard" do
    sign_in(author)

    get dashboard_path

    expect(response.body).to include('id="coming"')
    expect(response.body).to include('id="mygames"')
  end

  it "keeps table#stats on the live stats page" do
    game = create_game(:author => author, :is_draft => false)
    game.update_column(:starts_at, 1.hour.ago)
    create_game_passing(:level => create_level(:game => game))
    sign_in(author)

    get game_stats_path(game)

    expect(response.body).to match(/<table[^>]*id="stats"/)
  end
end
