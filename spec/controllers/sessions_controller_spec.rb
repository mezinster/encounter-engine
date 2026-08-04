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

  it "does not let a pre-existing session key survive login (session fixation)" do
    session[:attacker_planted] = "still here?"
    post :create, params: { email: "iv@diesel.kg", password: "1234" }
    expect(session[:attacker_planted]).to be_nil
    expect(session[:user_id]).to eq(user.id)
  end

  it "signs a user out" do
    session[:user_id] = user.id
    delete :destroy
    expect(session[:user_id]).to be_nil
  end

  it "clears the whole session on logout, not just user_id" do
    session[:user_id] = user.id
    session[:some_other_key] = "leftover"
    delete :destroy
    expect(session[:user_id]).to be_nil
    expect(session[:some_other_key]).to be_nil
  end

  it "does not raise on GET /logout for a visitor who was never logged in" do
    expect { get :destroy }.not_to raise_error
    expect(session[:user_id]).to be_nil
  end

  it "does not raise on DELETE /logout for a visitor who was never logged in" do
    expect { delete :destroy }.not_to raise_error
    expect(session[:user_id]).to be_nil
  end
end
