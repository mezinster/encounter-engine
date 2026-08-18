# -*- encoding : utf-8 -*-
require "rails_helper"

# Regression coverage for the visibility-default polarity bug: the column's
# default was briefly "draft" (the opposite of is_draft's old
# `default: false`), and because the author form binds the checkbox with
# f.check_box :visibility, {}, "draft", "listed", a "draft" default rendered
# the checkbox CHECKED on a brand-new game. Every game created through the
# form without touching that checkbox silently became a draft, which is what
# took 97 inherited Cucumber scenarios down (see
# db/migrate/20260818155000_correct_visibility_default_on_games.rb). A model
# spec on Game.new.visibility alone would not have caught this -- the defect
# was in what the form rendered, not in the model default by itself.
describe "creating a game leaves it published unless the author drafts it", type: :request do
  let(:author) { create_user }

  def sign_in(user)
    put login_path, :params => { :email => user.email, :password => "1234" }
  end

  it "does not render the new-game visibility checkbox as checked" do
    sign_in(author)

    get new_game_path

    expect(response).to have_http_status(:ok)
    checkbox = response.body[/<input[^>]*type="checkbox"[^>]*name="game\[visibility\]"[^>]*>/]
    expect(checkbox).to be_present
    expect(checkbox).not_to include("checked")
  end

  it "creates a listed game when the form is posted without naming visibility" do
    sign_in(author)

    post games_path, :params => {
      :game => {
        :name => "Котлованы Бишкека",
        :description => "Общий старт у ЦУМа",
        :starts_at => "2099-01-01 00:00",
        :max_team_number => "2"
      }
    }

    game = Game.find_by!(:name => "Котлованы Бишкека")
    expect(game.visibility).to eq("listed")
    expect(game.draft?).to be false
  end
end
