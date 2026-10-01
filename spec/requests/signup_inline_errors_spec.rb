require "rails_helper"

# The real signup form, submitted with a blank nickname. User's messages are
# full sentences from the Merb era ("Вы не ввели имя"), not predicates; they
# read correctly under the field either way. The literal is pinned rather than
# I18n.t(...), which would also pass if the key went missing.
describe "inline errors on the signup form", type: :request do
  before do
    post users_path, :params => { :user => { :nickname => "", :email => "inline@example.com" } }
  end

  let(:doc) { Nokogiri::HTML(response.body) }

  it "re-renders the form as unprocessable" do
    expect(response).to have_http_status(:unprocessable_entity)
  end

  it "puts the nickname message directly under the nickname field" do
    input = doc.at_css("input#user_nickname")
    expect(input["aria-invalid"]).to eq("true")
    expect(input.next_element["id"]).to eq("user_nickname-error")
    expect(input.next_element.text).to eq("Вы не ввели имя")
  end

  it "still renders the summary, announced as an alert" do
    summary = doc.at_css("div.error")
    expect(summary["role"]).to eq("alert")
    expect(summary.text).to include("Вы не ввели имя")
  end
end
