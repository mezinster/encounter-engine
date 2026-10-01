require "rails_helper"

# Merb-era messages are whole sentences ("Вы не ввели имя"). Rails' summary
# composes "%{attribute} %{message}", so they rendered as "Nickname Вы не ввели
# имя". With per-field formats the sentence stands alone. Literals pinned, not
# I18n.t(...), which would pass even if the key went missing.
describe "full-sentence error messages", type: :request do
  let(:summary_items) { Nokogiri::HTML(response.body).css("div.error li").map { |li| li.text.strip } }

  it "renders the signup nickname message without a field name" do
    post users_path, :params => { :user => { :nickname => "", :email => "sentence@example.com" } }

    expect(summary_items).to include("Вы не ввели имя")
    expect(summary_items.join).not_to include("Nickname")
  end

  it "renders the game name message without a field name" do
    author = create_user
    put login_path, :params => { :email => author.email, :password => "1234" }
    post games_path, :params => { :game => { :name => "", :description => "x", :max_team_number => "2" } }

    expect(summary_items).to include("Вы не ввели название")
    expect(summary_items).not_to include(a_string_starting_with("Название "))
  end
end
