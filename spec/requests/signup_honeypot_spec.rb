require "rails_helper"

describe "the signup honeypot", type: :request do
  it "creates no user and sends no mail when the trap field is filled" do
    expect {
      expect {
        post users_path, :params => { :user => { :nickname => "bot", :email => "bot@example.com" },
                                      :website => "http://spam.example" }
      }.not_to change { User.count }
    }.not_to change { ActionMailer::Base.deliveries.size }
  end

  # The response must not tell the operator of a bot which field gave them
  # away, or the trap is worth nothing after the first attempt.
  it "answers a trapped submission with an ordinary redirect" do
    post users_path, :params => { :user => { :nickname => "bot", :email => "bot@example.com" },
                                  :website => "http://spam.example" }

    expect(response).to have_http_status(:found)
    expect(response.body).not_to include("website")
  end

  it "still registers a normal submission with the field left empty" do
    expect {
      post users_path, :params => { :user => { :nickname => "human", :email => "human@example.com" },
                                    :website => "" }
    }.to change { User.count }.by(1)
  end

  # An absent parameter is the normal case for anything that is not a browser
  # rendering the form -- the Cucumber suite included.
  it "still registers when the field is absent entirely" do
    expect {
      post users_path, :params => { :user => { :nickname => "curl", :email => "curl@example.com" } }
    }.to change { User.count }.by(1)
  end

  it "renders the trap field on the form" do
    get signup_path

    expect(response.body).to include('name="website"')
    expect(response.body).to include('aria-hidden="true"')
  end
end
