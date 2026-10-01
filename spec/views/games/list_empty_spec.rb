require "rails_helper"

# M7: games/_list follows games/_game_entries -- an explicit empty_text: nil
# means "no sentence", and leaving the key out means the default sentence.
describe "games/_list when empty", type: :view do
  # The partial's helpers ask about the viewer; a view spec has no controller
  # concern behind them, so the viewer is a guest here.
  before do
    view.define_singleton_method(:logged_in?) { false }
    view.define_singleton_method(:current_user) { nil }
  end

  def card
    Nokogiri::HTML(rendered).at_css(".empty-state")
  end

  it "uses the default sentence when no empty_text is given" do
    render :partial => "games/list", :locals => { :games => [] }
    expect(card.at_css(".empty-state-title").text).to eq("Игр пока нет")
    expect(card.at_css("p").text).to eq("Здесь появятся игры, как только их опубликуют.")
  end

  it "uses the caller's sentence" do
    render :partial => "games/list", :locals => { :games => [], :empty_text => "Созданные вами игры появятся здесь." }
    expect(card.at_css("p").text).to eq("Созданные вами игры появятся здесь.")
  end

  it "renders no sentence for an explicit nil" do
    render :partial => "games/list", :locals => { :games => [], :empty_text => nil }
    expect(card.at_css(".empty-state-title").text).to eq("Игр пока нет")
    expect(card.at_css("p")).to be_nil
  end
end
