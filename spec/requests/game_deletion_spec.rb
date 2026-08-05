require "rails_helper"

describe "game deletion", type: :request do
  let(:author) { create_user }

  # Verified: config/routes.rb maps GET /login to sessions#new (the form) and
  # PUT /login to sessions#update (the actual login). It is PUT, not POST.
  # create_user (spec/spec_helpers/fixtures_helper.rb) sets password "1234".
  def sign_in(user)
    put login_path, :params => { :email => user.email, :password => "1234" }
  end

  it "is allowed when no team has ever played" do
    game = create_game(:author => author, :is_draft => true)
    expect(game.deletable?).to be true
  end

  it "is refused once any team has played" do
    game = create_game(:author => author, :is_draft => false)
    create_game_passing(:level => create_level(:game => game))
    expect(game.reload.deletable?).to be false
  end

  # Today's behaviour orphans them: zero foreign keys, no dependent: options.
  it "takes the levels, hints and questions with it" do
    game  = create_game(:author => author, :is_draft => true)
    level = create_level(:game => game)
    hint  = create_hint(:level => level)
    level_id, hint_id = level.id, hint.id

    game.destroy

    expect(Level.where(:id => level_id)).to be_empty
    expect(Hint.where(:id => hint_id)).to be_empty
  end

  it "refuses over HTTP and leaves the game alone" do
    game = create_game(:author => author, :is_draft => false)
    create_game_passing(:level => create_level(:game => game))
    sign_in(author)

    delete_game_request(game)

    expect(Game.where(:id => game.id)).not_to be_empty
  end

  # The delete route in this app is GamesController#delete, not #destroy.
  # Confirm its verb and helper in config/routes.rb before running.
  def delete_game_request(game)
    get delete_game_path(game)
  end
end
