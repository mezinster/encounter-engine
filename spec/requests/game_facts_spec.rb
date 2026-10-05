require "rails_helper"

# The game page's facts panel: each field a labelled tile, the description a
# section of its own. Two frozen features read this panel as plain text --
# features/games/max-team-number.feature:22-27 needs "Автор - avthor",
# "Описание:" and "Максимальное количество команд:", and
# features/games/game-profile.feature:14 needs /Автор.*Iv/ -- so the " - " and
# the colons stay in the markup as .fact-sep spans that only an external
# stylesheet hides (rack-test reads no stylesheet; see CLAUDE.md on the locale
# dropdown). These examples pin that the separators are still there, and where.
describe "the game page's facts panel", type: :request do
  let(:author) { create_user }

  def sign_in(user)
    put login_path, :params => { :email => user.email, :password => "1234" }
  end

  def facts
    Nokogiri::HTML(response.body).at_css(".game-facts")
  end

  let(:game) do
    g = create_game(:author => author, :description => "Первая строка\nВторая строка", :max_team_number => 5)
    set_game_schedule!(g, :starts_at => 2.days.from_now, :registration_deadline => 1.day.from_now)
  end

  it "renders each field as a labelled tile, separators kept in the label" do
    get game_path(game)

    labels = facts.css("dl.facts > .fact > dt").map(&:text)
    expect(labels).to eq(["Автор - ", "Начало игры:", "Крайний срок регистрации:",
                          "Максимальное количество команд:"])
    expect(facts.css("dl.facts dt .fact-sep").size).to eq(4)
    expect(facts.at_css(".fact--author dd").text.strip).to eq(author.nickname)
    expect(facts.at_css(".fact--max-teams dd").text.strip).to eq("5")
  end

  it "keeps the frozen texts contiguous for the acceptance suite" do
    get game_path(game)

    text = facts.text.gsub(/\s+/, " ")
    expect(text).to include("Автор - #{author.nickname}")
    expect(text).to include("Описание:")
    expect(text).to include("Максимальное количество команд:")
  end

  it "gives the description its own section with its line breaks" do
    get game_path(game)

    section = facts.at_css(".game-description")
    expect(section.at_css(".fact-label").text).to eq("Описание:")
    expect(section.at_css(".game-description-text").inner_html).to include("Первая строка<br>Вторая строка")
  end

  it "puts the countdown inside the start tile" do
    get game_path(game)

    expect(facts.at_css(".fact--starts #countdown-example")).not_to be_nil
  end

  it "says so in the tile when no start is scheduled" do
    unscheduled = create_game(:author => author)
    set_game_schedule!(unscheduled, :starts_at => nil, :registration_deadline => nil)
    # The author: a guest gets 401 on a game with no start, and the frozen
    # create-game.feature:99 reads this sentence as the author too.
    sign_in(author)
    get game_path(unscheduled)

    expect(facts.at_css(".fact--starts dd").text).to include("Дата начала игры ещё не назначена")
    expect(facts.at_css(".fact--deadline dd").text).to include("Крайний срок регистрации ещё не назначен")
  end

  it "puts the operator's pass and code buttons in one row" do
    operator = create_user
    operator.update!(:is_operator => true)
    game.update!(:access_mode => "pass_required")
    sign_in(operator)
    get game_path(game)

    row = Nokogiri::HTML(response.body).css(".game-control").find { |el| el.at_css("a[href='#{game_access_passes_path(game)}']") }
    expect(row).not_to be_nil
    expect(row.css("a.btn").map { |a| a["href"] }).to eq([game_access_passes_path(game), game_access_codes_path(game)])
  end
end
