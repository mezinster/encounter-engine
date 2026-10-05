require "rails_helper"

# The author's level page as a sectioned sheet: a breadcrumb to the game, the
# task text and the codes as labelled sections, each code a row with its own
# actions, hints as rows with a delay badge. Frozen features read this page as
# text -- managing-additional-codes.feature:17 needs "Коды (2)" and :28 must NOT
# see "Коды (2):" after a refused duplicate, which is only a real check while
# the colon is still in the text -- so the colons stay in the markup as
# .fact-sep spans that only screens.css hides, as on the game page.
describe "the author's level page", type: :request do
  let(:author) { create_user }
  let(:game) { create_game(:author => author, :name => "Сокровище нации") }
  let(:level) do
    create_level(:game => game, :name => "Сокровищница", :correct_answer => "tr1122",
                 :text => "Первая строка\nВторая строка")
  end

  def sign_in(user)
    put login_path, :params => { :email => user.email, :password => "1234" }
  end

  def doc
    Nokogiri::HTML(response.body)
  end

  def sheet
    doc.at_css(".level-sheet")
  end

  before { sign_in(author) }

  it "links back to the game above the heading" do
    get game_level_path(game, level)

    crumb = doc.at_css(".breadcrumb a")
    expect(crumb["href"]).to eq(game_path(game))
    expect(crumb.text).to include("Сокровище нации")
  end

  it "labels the task text as a section, colon kept for the acceptance suite" do
    get game_level_path(game, level)

    section = sheet.at_css(".sheet-section--text")
    expect(section.at_css(".fact-label").text).to eq("Текст задания:")
    expect(section.at_css(".fact-label .fact-sep").text).to eq(":")
    expect(section.at_css(".level-text").inner_html).to include("Первая строка<br>Вторая строка")
    expect(section.at_css("a.btn[href='#{edit_game_level_path(game, level)}']")).not_to be_nil
  end

  it "shows a single code as a row, under a singular label" do
    get game_level_path(game, level)

    codes = sheet.at_css(".sheet-section--codes")
    expect(codes.at_css(".fact-label").text).to eq("Код:")
    rows = codes.css(".code-row")
    expect(rows.size).to eq(1)
    expect(rows.first["id"]).to eq("question-#{level.questions.first.id}")
    expect(rows.first.at_css(".code-chip").text.strip).to eq("tr1122")
    expect(rows.first.at_css("a").text).to eq("(редактировать)")
  end

  it "shows several codes as rows, each with its own delete button" do
    create_question(:level => level, :correct_answer => "tr1133")
    get game_level_path(game, level)

    codes = sheet.at_css(".sheet-section--codes")
    expect(codes.at_css(".fact-label").text).to eq("Коды (2):")
    expect(codes.css(".code-row .code-chip").map { |c| c.text.strip }).to eq(%w[tr1122 tr1133])
    expect(codes.css(".code-row").map { |r| r.at_css("button.btn--danger")&.text }).to all(eq("Удалить код"))
  end

  it "shows the any/all rule as a tag beside the codes label" do
    get game_level_path(game, level)

    expect(sheet.at_css(".sheet-section--codes .sheet-heading .tag").text.strip).to eq("Достаточно любого из кодов")
  end

  it "puts adding a code and the answer options in one row" do
    get game_level_path(game, level)

    row = sheet.at_css(".sheet-section--codes .game-control")
    expect(row.css("a.btn").map(&:text)).to eq(["Добавить ещё один код", "Варианты ответа"])
  end

  it "shows each hint as a row with its delay in a badge" do
    create_hint(:level => level, :text => "Ищите у фонтана", :delay => 600)
    get game_level_path(game, level)

    expect(doc.at_css(".hints-card legend").text).to eq("Подсказки:")
    row = doc.at_css(".hints-card .hint-row")
    expect(row.at_css(".tag").text.gsub(/\s+/, " ").strip).to eq("Через 10 минут")
    expect(row.at_css(".hint-body").text).to include("Ищите у фонтана")
    expect(row.at_css("button.btn--danger").text).to eq("(удалить)")
  end

  # Before this page was restyled the delay was rendered only as the edit link,
  # and the link is withheld once the game starts -- so a started game's hints
  # lost their delay altogether.
  it "still shows a hint's delay once the game has started" do
    game.update!(:visibility => "listed")
    set_game_schedule!(game, :starts_at => 1.hour.ago)
    create_hint(:level => level, :text => "Ищите у фонтана", :delay => 600)
    get game_level_path(game, level)

    badge = doc.at_css(".hints-card .hint-row .tag")
    expect(badge.text.gsub(/\s+/, " ").strip).to eq("Через 10 минут")
    expect(badge.at_css("a")).to be_nil
  end
end
