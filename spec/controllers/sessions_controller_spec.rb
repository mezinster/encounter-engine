# -*- encoding : utf-8 -*-
require "rails_helper"

RSpec.describe SessionsController, type: :controller do
  let!(:user) do
    User.create!(nickname: "iv", email: "iv@diesel.kg",
                 password: "1234", password_confirmation: "1234")
  end

  it "signs a user in with correct credentials" do
    post :create, params: { email: "iv@diesel.kg", password: "1234" }
    expect(session[:user_id]).to eq(user.id)
  end

  it "rejects a wrong password" do
    post :create, params: { email: "iv@diesel.kg", password: "wrong" }
    expect(session[:user_id]).to be_nil
  end

  it "signs a user out" do
    session[:user_id] = user.id
    delete :destroy
    expect(session[:user_id]).to be_nil
  end
end
