# -*- encoding : utf-8 -*-
require "rails_helper"

# Ported from the Merb-era `request(resource(:users, :new))` spec.
# spec/requests/view_smoke_spec.rb covers GET /signup; this covers the other
# route that reaches the same action -- `resources :users` still serves
# /users/new, and the Merb original asked for that one specifically.
RSpec.describe "GET /users/new", type: :request do
  it "responds successfully to a guest" do
    get new_user_path

    expect(response).to have_http_status(:ok)
  end
end
