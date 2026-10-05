require "rails_helper"

# The per-game admin page: every per-game control the games list used to carry
# in each row, grouped into panels. Each control keeps the predicate it had on
# the list -- offering a control the action refuses is a promise the page
# cannot keep.
describe "the superadmin's game page", type: :request do
  let(:author)     { create_user }
  let(:superadmin) { u = create_user; u.update!(:is_superadmin => true); u }

  def sign_in(user)
    put login_path, :params => { :email => user.email, :password => "1234" }
  end

  def doc
    Nokogiri::HTML(response.body)
  end

  def panel(key)
    doc.at_css(".admin-panel--#{key}")
  end

  def finished_with_level
    g = create_game(:author => author, :is_draft => false)
    create_level(:game => g)
    set_game_schedule!(g, :starts_at => 2.days.ago, :author_finished_at => 1.day.ago)
    g
  end

  it "refuses an anonymous visitor" do
    get admin_game_path(create_game(:author => author))
    expect(response).to redirect_to(login_path)
  end

  it "refuses an ordinary signed-in user" do
    sign_in(author)
    get admin_game_path(create_game(:author => author))
    expect(response).to have_http_status(:unauthorized)
  end

  it "shows the game's name, author, status and facts" do
    game = create_game(:author => author, :is_draft => false, :name => "Ночной Бишкек", :max_team_number => 20)
    sign_in(superadmin)
    get admin_game_path(game)

    expect(doc.at_css("h1").text).to include("Ночной Бишкек")
    expect(doc.at_css("h1 a")["href"]).to eq(game_path(game))
    expect(doc.at_css(".admin-game-meta").text).to include(author.nickname)
    expect(doc.at_css(".admin-game-meta .tag")).not_to be_nil
    expect(doc.css(".facts .fact-label").map { |l| l.text.strip }).to eq(%w[Команды Играют Языки Забег])
    expect(doc.at_css(".facts").text).to include("0 / 20")
  end

  it "offers withdraw, lock, applications and edit for a fresh listed game -- and delete" do
    game = create_game(:author => author, :is_draft => false)
    sign_in(superadmin)
    get admin_game_path(game)

    expect(panel("state").at_css("a[href='#{new_withdrawal_game_path(game)}']")).not_to be_nil
    expect(panel("state").to_html).to match(%r{<form[^>]*action="#{Regexp.escape(lock_game_path(game))}"})
    expect(panel("state").to_html).not_to include(restore_game_path(game))
    expect(panel("state").to_html).not_to include(unfinish_game_path(game))
    expect(panel("entries").at_css("a[href='#{admin_game_entries_path(game)}']").text).to eq("Заявки (0)")
    expect(panel("entries").at_css("a[href='#{edit_game_path(game)}']")).not_to be_nil
    expect(panel("author").at_css("form[action='#{set_author_admin_game_path(game)}']")).not_to be_nil
    expect(panel("new-run")).to be_nil
    expect(panel("danger").to_html).to include(delete_game_path(game))
  end

  # Withdrawal, author-finish and the editing lock are independent facts; a game
  # that is all three must offer every way back at once.
  it "offers restore, unfinish and unlock together on a withdrawn, finished, locked game" do
    game = finished_with_level
    game.withdraw!(:category => "other", :mode => "freeze")
    game.lock_editing!
    sign_in(superadmin)
    get admin_game_path(game)

    html = panel("state").to_html
    expect(html).to match(%r{<form[^>]*action="#{Regexp.escape(restore_game_path(game))}"})
    expect(html).to match(%r{<form[^>]*action="#{Regexp.escape(unfinish_game_path(game))}"})
    expect(html).to match(%r{<form[^>]*action="#{Regexp.escape(unlock_game_path(game))}"})
    expect(html).not_to include(new_withdrawal_game_path(game))
    expect(html).not_to include(lock_game_path(game) + '"')
  end

  it "offers a new run, with its three fields, only for a finished game with levels" do
    game = finished_with_level
    sign_in(superadmin)
    get admin_game_path(game)

    form = panel("new-run").at_css("form[action='#{open_run_admin_game_path(game)}']")
    expect(form.at_css("input[name='starts_at']")["type"]).to eq("datetime-local")
    expect(form.at_css("input[name='registration_deadline']")["type"]).to eq("datetime-local")
    expect(form.at_css("input[name='max_team_number']")["type"]).to eq("number")
  end

  it "offers no edit link once the game has started" do
    game = create_game(:author => author, :is_draft => false)
    set_game_schedule!(game, :starts_at => 1.hour.ago)
    sign_in(superadmin)
    get admin_game_path(game)

    expect(panel("entries").to_html).not_to include(edit_game_path(game))
  end

  it "offers no delete for a game that has been played" do
    played = create_game(:author => author, :is_draft => false)
    create_game_passing(:level => create_level(:game => played))
    sign_in(superadmin)
    get admin_game_path(played)

    expect(panel("danger")).to be_nil
    expect(response.body).not_to include(delete_game_path(played))
  end

  it "counts only the current run's pending applications" do
    game = create_game(:author => author, :is_draft => false)
    create_game_entry(:game => game, :team => create_team(:captain => create_user), :status => "new")
    sign_in(superadmin)
    get admin_game_path(game)

    expect(panel("entries").at_css("a[href='#{admin_game_entries_path(game)}']").text).to eq("Заявки (1)")
  end
end
