require "rails_helper"

RSpec.describe "health endpoint", type: :request do
  it "returns 200 so kamal-proxy can health-check the container" do
    get "/up"
    expect(response).to have_http_status(:ok)
  end
end
