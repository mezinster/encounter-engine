require "rails_helper"

describe "shared/_empty_state", type: :view do
  it "renders a card with a title, a sentence and a quiet action link" do
    render :partial => "shared/empty_state",
           :locals => { :title => "Команд пока нет", :text => "Создайте первую.", :action => [ "Создать команду", "/teams/new" ] }
    card = Nokogiri::HTML(rendered).at_css("div.card.empty-state")
    expect(card.at_css("h3.empty-state-title").text).to eq("Команд пока нет")
    expect(card.at_css("p").text).to eq("Создайте первую.")
    link = card.at_css("a.empty-state-action")
    expect([ link.text, link["href"] ]).to eq([ "Создать команду", "/teams/new" ])
    expect(link["class"]).not_to include("btn--go")
  end

  it "honours the heading level" do
    render :partial => "shared/empty_state", :locals => { :title => "Игр пока нет", :heading => :h2 }
    expect(Nokogiri::HTML(rendered).at_css("h2.empty-state-title")).to be_present
  end

  it "renders a one-line variant" do
    render :partial => "shared/empty_state", :locals => { :title => "Ответов нет", :variant => :line }
    doc = Nokogiri::HTML(rendered)
    expect(doc.at_css("p.empty-state-line").text).to eq("Ответов нет")
    expect(doc.at_css(".card")).to be_nil
  end
end
