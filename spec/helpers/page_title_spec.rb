require "rails_helper"

describe ApplicationHelper, "#page_title", type: :helper do
  let(:site) { "Активные городские игры" }

  it "is the site name alone when a view set no title" do
    expect(helper.page_title_text).to eq(site)
  end

  it "puts the page first, then the site" do
    helper.page_title("Команды")
    expect(helper.page_title_text).to eq("Команды · #{site}")
  end

  it "adds the game between page and site" do
    helper.page_title("Турнирная таблица", game: double(:name => "Ночной дозор"))
    expect(helper.page_title_text).to eq("Турнирная таблица — Ночной дозор · #{site}")
  end

  it "uses the game alone when there is no page part" do
    helper.page_title(nil, game: double(:name => "Ночной дозор"))
    expect(helper.page_title_text).to eq("Ночной дозор · #{site}")
  end

  it "returns plain text; the layout's ERB escapes an author's markup" do
    helper.page_title(nil, game: double(:name => %(<b>Игра "А&Б"</b>)))
    expect(helper.page_title_text).to eq(%(<b>Игра "А&Б"</b> · #{site}))
    expect(helper.page_title_text).not_to be_html_safe
  end
end
