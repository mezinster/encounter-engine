require "rails_helper"

describe "auditing administrative changes", type: :request do
  let(:author)     { create_user }
  let(:superadmin) { u = create_user; u.update!(:is_superadmin => true); u }
  let(:game)       { create_game(:author => author, :is_draft => true) }

  def sign_in(user)
    put login_path, :params => { :email => user.email, :password => "1234" }
  end

  # admin_actions.actor_id is null: false in the schema but optional: true in
  # the model, and the audit view already renders «неизвестно» when the actor
  # is missing. Deleting an operator therefore turned every action they ever
  # took into an unattributable row -- in a log this codebase documents as
  # append-only. target_label exists for exactly that hazard on the TARGET
  # side, with a comment calling "a number nobody can resolve" the worst
  # possible audit outcome; there was no actor equivalent. Phase 6 needs one
  # before it can delete anybody.
  describe "surviving the deletion of the actor" do
    before { sign_in(superadmin) }

    it "snapshots the actor's nickname when the action is recorded" do
      post withdraw_game_path(game)

      expect(AdminAction.newest_first.first.actor_label).to eq(superadmin.nickname)
    end

    it "still names the actor on screen after their row is gone" do
      post withdraw_game_path(game)
      remembered = superadmin.nickname
      AdminAction.update_all(:actor_id => 0)

      operator = create_user
      operator.update!(:is_superadmin => true)
      sign_in(operator)
      get admin_audit_index_path

      expect(response.body).to include(remembered)
      expect(response.body).not_to include(I18n.t("admin.audit.index.unknown_actor"))
    end
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

    it "records opening a run" do
      finished = create_game(:author => author, :is_draft => false)
      create_level(:game => finished)
      set_game_schedule!(finished, :starts_at => 2.days.ago, :author_finished_at => 1.day.ago)

      expect do
        post open_run_admin_game_path(finished),
             :params => { :starts_at => 2.years.from_now.strftime("%Y-%m-%d %H:%M"),
                          :registration_deadline => 23.months.from_now.strftime("%Y-%m-%d %H:%M"),
                          :max_team_number => "10" }
      end.to change { AdminAction.count }.by(1)

      expect(AdminAction.newest_first.first.action).to eq("open_run")
    end

    it "records an author reassignment" do
      successor = create_user

      expect do
        post set_author_admin_game_path(game), :params => { :nickname => successor.nickname }
      end.to change { AdminAction.count }.by(1)

      expect(AdminAction.newest_first.first.action).to eq("set_author")
    end
  end

  describe "the inherited actions, performed on someone else's game" do
    before { sign_in(superadmin) }

    it "records a deletion, and still names the game afterwards" do
      name = game.name
      expect { delete delete_game_path(game) }.to change { AdminAction.count }.by(1)

      entry = AdminAction.newest_first.first
      expect(entry.action).to eq("delete")
      expect(entry.target_label).to eq(name)
      expect(Game.where(:id => entry.target_id)).to be_empty
    end

    it "records ending a game" do
      expect { post end_game_game_path(game) }.to change { AdminAction.count }.by(1)
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
      expect { post start_test_game_path(game) }.to change { AdminAction.count }.by(1)
      expect(AdminAction.newest_first.first.action).to eq("start_test")
    end

    it "records finishing a test" do
      testing_game = create_game(:author => author, :is_testing => true, :test_date => "2099-02-02 00:00")

      expect { post finish_test_game_path(testing_game) }.to change { AdminAction.count }.by(1)
      expect(AdminAction.newest_first.first.action).to eq("finish_test")
    end
  end

  # The condition is "superadmin AND not the author". Getting it wrong in the
  # other direction floods the log with ordinary use and buries the entries
  # anyone actually wants to find.
  describe "an author acting on their own game" do
    it "records nothing" do
      sign_in(author)
      expect { post end_game_game_path(game) }.not_to change { AdminAction.count }
    end

    # acting_as_operator? is "superadmin AND not the author". The example
    # above only exercises a non-superadmin author; this is the other half of
    # the conjunction -- a superadmin who is ALSO the author must still record
    # nothing, or the log would bury every superadmin's ordinary games under
    # administrative noise.
    it "records nothing when the author is also a superadmin" do
      author.update!(:is_superadmin => true)
      sign_in(author)
      expect { post end_game_game_path(game) }.not_to change { AdminAction.count }
    end
  end

  # Entries are written only once the change has landed. An entry for a
  # deletion that was refused would make the log unreadable.
  describe "a refused action" do
    it "records nothing" do
      played = create_game(:author => author, :is_draft => false)
      create_game_passing(:level => create_level(:game => played))
      sign_in(superadmin)

      expect { delete delete_game_path(played) }.not_to change { AdminAction.count }
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
      delete delete_game_path(game)

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
