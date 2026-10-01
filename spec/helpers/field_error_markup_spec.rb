require "rails_helper"

# Goes through the real form helpers, so it exercises the field_error_proc
# wiring in config/application.rb as well as FieldErrorMarkup itself.
# Errors are added by hand: no database, no validations, one known message.
describe FieldErrorMarkup, type: :helper do
  let(:game) { Game.new }

  def html(markup) = Nokogiri::HTML::DocumentFragment.parse(markup)

  context "an invalid text field" do
    before { game.errors.add(:name, "не может быть пустым") }
    let(:out) { helper.text_field(:game, :name, :object => game) }

    it "marks the control invalid" do
      input = html(out).at_css("input#game_name")
      expect(input["aria-invalid"]).to eq("true")
      expect(input["class"].split).to include("is-invalid")
    end

    it "links the control to its message" do
      doc = html(out)
      expect(doc.at_css("input#game_name")["aria-describedby"]).to eq("game_name-error")
      expect(doc.at_css("span.field-error#game_name-error").text).to eq("не может быть пустым")
    end

    it "does not wrap anything in Rails' field_with_errors div" do
      expect(out).not_to include("field_with_errors")
    end
  end

  it "joins several messages for one field" do
    game.errors.add(:name, "первое")
    game.errors.add(:name, "второе")
    out = helper.text_field(:game, :name, :object => game)
    expect(html(out).at_css("#game_name-error").text).to eq("первое; второе")
  end

  it "escapes a message, even one already marked html_safe" do
    game.errors.add(:name, "<b>жирный</b>".html_safe)
    out = helper.text_field(:game, :name, :object => game)
    expect(out).to include("&lt;b&gt;жирный&lt;/b&gt;")
    expect(html(out).at_css("#game_name-error b")).to be_nil
  end

  it "keeps a self-closing input valid" do
    game.errors.add(:name, "x")
    out = helper.text_field(:game, :name, :object => game)
    expect(out).not_to match(%r{/\s+aria-})
    expect(html(out).css("input").size).to eq(1)
  end

  it "keeps a textarea's content byte for byte, leading newline included" do
    game.description = "\nвторая строка"
    game.errors.add(:description, "x")
    out = helper.text_area(:game, :description, :object => game)
    expect(out).to include(">\n\nвторая строка</textarea>")
  end

  it "marks a radio button but gives it no message span" do
    game.errors.add(:visibility, "x")
    out = helper.radio_button(:game, :visibility, "draft", :object => game)
    expect(html(out).at_css("input[type=radio]")["aria-invalid"]).to eq("true")
    expect(out).not_to include("field-error")
  end

  it "gives a checkbox its message and leaves the companion hidden input alone" do
    game.errors.add(:points_enabled, "x")
    out = helper.check_box(:game, :points_enabled, :object => game)
    doc = html(out)
    expect(doc.at_css("input[type=hidden]")["aria-invalid"]).to be_nil
    expect(doc.at_css("input[type=checkbox]")["aria-invalid"]).to eq("true")
    expect(doc.at_css("#game_points_enabled-error").text).to eq("x")
  end

  it "gives a label the class and nothing else" do
    game.errors.add(:name, "x")
    out = helper.label(:game, :name, "Название", :object => game)
    label = html(out).at_css("label")
    expect(label["class"].split).to include("is-invalid")
    expect(label["aria-invalid"]).to be_nil
    expect(out).not_to include("field-error")
  end

  it "leaves a valid field exactly as Rails renders it" do
    expect(helper.text_field(:game, :name, :object => game)).not_to include("is-invalid")
  end
end
