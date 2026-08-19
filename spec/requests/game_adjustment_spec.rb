require "rails_helper"

describe "an operator adjusting a team's points for one game", type: :request do
  def sign_in(user)
    put login_path, :params => { :email => user.email, :password => "1234" }
  end

  def live_game_with_passing(attrs = {})
    author  = attrs[:author] || create_user
    game    = create_game(:author => author)
    level   = create_level(:game => game, :position => 1)
    create_level(:game => game, :position => 2)
    set_game_schedule!(game, :starts_at => 1.hour.ago)
    passing = create_game_passing(:level => level)
    [ author, game, passing ]
  end

  it "shows a form, then a confirmation, then writes on the confirmed post" do
    author, game, passing = live_game_with_passing
    sign_in(author)

    get new_team_adjustment_path(:game_id => game.id, :team_id => passing.team_id)
    expect(response).to have_http_status(:ok)

    post team_adjustments_path(:game_id => game.id, :team_id => passing.team_id),
         :params => { :amount => -50, :note => "Пропустили точку" }
    expect(response).to have_http_status(:ok)
    expect(response.body).to include("-50")
    expect(response.body).to include("Пропустили точку")
    expect(PointTransaction.where(:reason => "adjustment").count).to eq(0)

    post team_adjustments_path(:game_id => game.id, :team_id => passing.team_id),
         :params => { :amount => -50, :note => "Пропустили точку", :confirmed => "1" }

    row = PointTransaction.find_by(:reason => "adjustment")
    expect(row.amount).to eq(-50)
    expect(row.note).to eq("Пропустили точку")
    expect(row.game_passing_id).to eq(passing.id)
    expect(row.created_by_id).to eq(author.id)
  end

  # A7. This is the example the whole task turns on.
  it "adjusts a FINISHED run" do
    author, game, passing = live_game_with_passing
    passing.update!(:finished_at => 1.hour.ago)
    sign_in(author)

    post team_adjustments_path(:game_id => game.id, :team_id => passing.team_id),
         :params => { :amount => 30, :note => "Точка была закрыта", :confirmed => "1" }

    expect(PointTransaction.where(:reason => "adjustment").count).to eq(1)
  end

  it "adjusts an EXITED run" do
    author, game, passing = live_game_with_passing
    passing.exit!
    sign_in(author)

    post team_adjustments_path(:game_id => game.id, :team_id => passing.team_id),
         :params => { :amount => 30, :note => "Компенсация", :confirmed => "1" }

    expect(PointTransaction.where(:reason => "adjustment").count).to eq(1)
  end

  # A7, the other half. ensure_game_is_live reads the GAME's own lifecycle
  # (started?/draft?/withdrawn?/author_finished?), not the PASSING's
  # finished_at/exited state -- so the two examples above never actually
  # reach that filter; they pass identically whether or not the exemption
  # below is present. This is the one example that reddens if
  # `skip_before_action :ensure_game_is_live, only: [:new_adjustment,
  # :create_adjustment]` is removed from InterventionsController: the author
  # has ended the whole game via finish_game!, which is exactly what
  # ensure_game_is_live gates on.
  it "adjusts a team's points after the author has ENDED THE GAME" do
    author, game, passing = live_game_with_passing
    game.finish_game!
    sign_in(author)

    post team_adjustments_path(:game_id => game.id, :team_id => passing.team_id),
         :params => { :amount => 30, :note => "Спор решён на следующее утро", :confirmed => "1" }

    expect(PointTransaction.where(:reason => "adjustment").count).to eq(1)
  end

  it "refuses a blank note without writing anything" do
    author, game, passing = live_game_with_passing
    sign_in(author)

    post team_adjustments_path(:game_id => game.id, :team_id => passing.team_id),
         :params => { :amount => -50, :note => "", :confirmed => "1" }

    expect(response).to have_http_status(:unprocessable_entity)
    expect(PointTransaction.where(:reason => "adjustment").count).to eq(0)
  end

  it "refuses an ordinary user" do
    _author, game, passing = live_game_with_passing
    sign_in(create_user)

    post team_adjustments_path(:game_id => game.id, :team_id => passing.team_id),
         :params => { :amount => -50, :note => "x", :confirmed => "1" }

    expect(response).to have_http_status(:unauthorized)
    expect(PointTransaction.where(:reason => "adjustment").count).to eq(0)
  end

  # Spec section 6 asks for author, superadmin AND operator-on-a-gated-game on
  # this door; only the author and the ordinary user were committed. The
  # operator clause is the line A4 draws its authority on -- ensure_author
  # admits an operator only where @game.pass_required? -- and without an
  # example nothing red follows from "simplifying" ensure_author off these two
  # actions. F5 of the whole-branch review.
  it "admits a superadmin on someone else's game" do
    _author, game, passing = live_game_with_passing
    admin = create_user
    admin.update!(:is_superadmin => true)
    sign_in(admin)

    post team_adjustments_path(:game_id => game.id, :team_id => passing.team_id),
         :params => { :amount => -50, :note => "Спор", :confirmed => "1" }

    expect(response).to have_http_status(:found)
    expect(PointTransaction.where(:reason => "adjustment").count).to eq(1)
  end

  # A gated attempt is resolved by GamePassing.gated_attempt_for, which reads
  # access_pass_id and never game_run_id -- hence the pass, and the passing
  # placed in no run at all, matching the fixtures in gated_standings_spec.
  it "admits an operator on a GATED game they did not author" do
    author = create_user
    game   = create_game(:author => author, :is_draft => false)
    game.update!(:access_mode => "pass_required")
    level  = create_level(:game => game, :position => 1)
    pass   = create_access_pass(:game => game)
    create_game_passing(:game => game, :team => pass.team, :level => level,
                        :game_run => nil, :access_pass => pass)

    operator = create_user
    operator.update!(:is_operator => true)
    sign_in(operator)

    post team_adjustments_path(:game_id => game.id, :team_id => pass.team_id),
         :params => { :amount => 20, :note => "Точка была закрыта", :confirmed => "1" }

    expect(response).to have_http_status(:found)
    expect(PointTransaction.where(:reason => "adjustment").count).to eq(1)
  end

  # Spec section 4.4: the audit records an adjustment ALWAYS, with the actor,
  # the team, the amount and the note.
  #
  # "Always" is the load-bearing word and it is why this goes through
  # record_admin_action rather than InterventionsController#audit: that helper
  # records only `if acting_as_operator?`, which is FALSE for an author acting
  # on their own game. That rule is right for pause/move/reset_clock -- ordinary
  # authoring acts on one game -- and wrong for an adjustment, which moves
  # points on a public cross-game chart and is answerable whoever wrote it.
  # F3 of the whole-branch review, where this path wrote zero audit rows.
  it "audits an author adjusting a team on their OWN game" do
    author, game, passing = live_game_with_passing
    sign_in(author)

    expect {
      post team_adjustments_path(:game_id => game.id, :team_id => passing.team_id),
           :params => { :amount => -50, :note => "Пропустили точку", :confirmed => "1" }
    }.to change { AdminAction.count }.by(1)

    entry = AdminAction.newest_first.first
    expect(entry.action).to eq("adjust_points")
    expect(entry.actor_id).to eq(author.id)
    expect(entry.target_id).to eq(game.id)
    expect(entry.details).to include(passing.team.name)
    expect(entry.details).to include("-50")
    expect(entry.details).to include("Пропустили точку")
  end

  it "audits a superadmin's adjustment with the amount and the note too" do
    _author, game, passing = live_game_with_passing
    admin = create_user
    admin.update!(:is_superadmin => true)
    sign_in(admin)

    expect {
      post team_adjustments_path(:game_id => game.id, :team_id => passing.team_id),
           :params => { :amount => 30, :note => "Компенсация", :confirmed => "1" }
    }.to change { AdminAction.count }.by(1)

    entry = AdminAction.newest_first.first
    expect(entry.actor_id).to eq(admin.id)
    expect(entry.details).to include(passing.team.name)
    expect(entry.details).to include("30")
    expect(entry.details).to include("Компенсация")
  end

  # The audit is written after the row lands, never before -- AdminAudit's own
  # rule, because an entry for a refused action makes the log unreadable.
  it "records nothing when the adjustment is refused" do
    author, game, passing = live_game_with_passing
    sign_in(author)

    expect {
      post team_adjustments_path(:game_id => game.id, :team_id => passing.team_id),
           :params => { :amount => -50, :note => "", :confirmed => "1" }
    }.not_to change { AdminAction.count }

    expect(response).to have_http_status(:unprocessable_entity)
  end
end
