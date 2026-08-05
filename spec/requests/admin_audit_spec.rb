require "rails_helper"

describe "auditing administrative changes", type: :request do
  let(:author)     { create_user }
  let(:superadmin) { u = create_user; u.update!(:is_superadmin => true); u }
  let(:game)       { create_game(:author => author, :is_draft => true) }

  def sign_in(user)
    put login_path, :params => { :email => user.email, :password => "1234" }
  end

  describe "the explicitly superadmin actions" do
    before { sign_in(superadmin) }

    it "records a withdrawal against the game" do
      expect { post withdraw_game_path(game) }.to change { AdminAction.count }.by(1)

      entry = AdminAction.newest_first.first
      expect(entry.action).to eq("withdraw")
      expect(entry.actor_id).to eq(superadmin.id)
      expect(entry.target_type).to eq("Game")
      expect(entry.target_id).to eq(game.id)
      expect(entry.target_label).to eq(game.name)
    end

    it "records a restore" do
      game.update!(:withdrawn_at => Time.now)
      expect { post restore_game_path(game) }.to change { AdminAction.count }.by(1)
      expect(AdminAction.newest_first.first.action).to eq("restore")
    end

    it "records a lock" do
      expect { post lock_game_path(game) }.to change { AdminAction.count }.by(1)
      expect(AdminAction.newest_first.first.action).to eq("lock")
    end

    it "records an unlock" do
      game.update!(:editing_locked_at => Time.now)
      expect { post unlock_game_path(game) }.to change { AdminAction.count }.by(1)
      expect(AdminAction.newest_first.first.action).to eq("unlock")
    end
  end

  describe "the inherited actions, performed on someone else's game" do
    before { sign_in(superadmin) }

    it "records a deletion, and still names the game afterwards" do
      name = game.name
      expect { get delete_game_path(game) }.to change { AdminAction.count }.by(1)

      entry = AdminAction.newest_first.first
      expect(entry.action).to eq("delete")
      expect(entry.target_label).to eq(name)
      expect(Game.where(:id => entry.target_id)).to be_empty
    end

    it "records ending a game" do
      expect { get "/games/end_game/#{game.id}" }.to change { AdminAction.count }.by(1)
      expect(AdminAction.newest_first.first.action).to eq("end_game")
    end

    it "records an update" do
      expect {
        put game_path(game), :params => { :game => { :name => "Renamed by operator" } }
      }.to change { AdminAction.count }.by(1)

      expect(AdminAction.newest_first.first.action).to eq("update")
    end

    it "records nothing when the update is rejected" do
      expect {
        put game_path(game), :params => { :game => { :name => "" } }
      }.not_to change { AdminAction.count }
    end

    it "records starting a test" do
      expect { get "/games/start_test/#{game.id}" }.to change { AdminAction.count }.by(1)
      expect(AdminAction.newest_first.first.action).to eq("start_test")
    end

    it "records finishing a test" do
      testing_game = create_game(:author => author, :is_testing => true, :test_date => "2099-02-02 00:00")

      expect { get "/games/finish_test/#{testing_game.id}" }.to change { AdminAction.count }.by(1)
      expect(AdminAction.newest_first.first.action).to eq("finish_test")
    end
  end

  # The condition is "superadmin AND not the author". Getting it wrong in the
  # other direction floods the log with ordinary use and buries the entries
  # anyone actually wants to find.
  describe "an author acting on their own game" do
    it "records nothing" do
      sign_in(author)
      expect { get "/games/end_game/#{game.id}" }.not_to change { AdminAction.count }
    end

    # acting_as_operator? is "superadmin AND not the author". The example
    # above only exercises a non-superadmin author; this is the other half of
    # the conjunction -- a superadmin who is ALSO the author must still record
    # nothing, or the log would bury every superadmin's ordinary games under
    # administrative noise.
    it "records nothing when the author is also a superadmin" do
      author.update!(:is_superadmin => true)
      sign_in(author)
      expect { get "/games/end_game/#{game.id}" }.not_to change { AdminAction.count }
    end
  end

  # Entries are written only once the change has landed. An entry for a
  # deletion that was refused would make the log unreadable.
  describe "a refused action" do
    it "records nothing" do
      played = create_game(:author => author, :is_draft => false)
      create_game_passing(:level => create_level(:game => played))
      sign_in(superadmin)

      expect { get delete_game_path(played) }.not_to change { AdminAction.count }
      expect(Game.where(:id => played.id)).not_to be_empty
    end
  end

  describe "the audit log screen" do
    it "refuses an anonymous visitor" do
      get admin_audit_index_path
      expect(response).to have_http_status(:found)
      expect(response).to redirect_to(login_path)
    end

    it "refuses an ordinary signed-in user" do
      sign_in(author)
      get admin_audit_index_path
      expect(response).to have_http_status(:unauthorized)
    end

    it "shows a superadmin the entries, naming a deleted target, without linking to it" do
      sign_in(superadmin)
      name = game.name
      id = game.id
      get delete_game_path(game)

      get admin_audit_index_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(name)
      expect(response.body).to include(superadmin.nickname)
      # target_label is a snapshot rendered as plain text once the target is
      # gone -- proving the label appears is not enough, since a link to the
      # dead id would render the same visible text. This must not link.
      expect(response.body).not_to include(%(href="/games/#{id}"))
    end

    it "links to a target that still exists" do
      sign_in(superadmin)
      post withdraw_game_path(game)

      get admin_audit_index_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(%(href="/games/#{game.id}"))
    end

    # This N+1 has been written into two consecutive plans on this project and
    # shipped once (see admin_reporting_spec.rb). It gets a test rather than a
    # comment. target_type/target_id are plain columns, not a polymorphic
    # association, so `includes` cannot preload the existence check -- this
    # pins the controller computing the live-id sets once instead.
    it "keeps the query count flat as the number of entries grows" do
      sign_in(superadmin)

      2.times { post withdraw_game_path(create_game(:author => author, :is_draft => true)) }
      small = count_queries { get admin_audit_index_path }

      8.times { post withdraw_game_path(create_game(:author => author, :is_draft => true)) }
      large = count_queries { get admin_audit_index_path }

      expect(large).to eq(small)
    end
  end

  describe "the details column" do
    it "is nil for an action that records none" do
      sign_in(superadmin)
      post withdraw_game_path(game)

      expect(AdminAction.newest_first.first.details).to be_nil
    end

    it "renders on the log screen when present" do
      sign_in(superadmin)
      AdminAction.create!(:actor_id => superadmin.id, :action => "move_team",
                          :target_type => "Game", :target_id => game.id,
                          :target_label => game.name, :details => "Команда Кентавры")

      get admin_audit_index_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Команда Кентавры")
    end
  end
end
