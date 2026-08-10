# -*- encoding : utf-8 -*-
require "rails_helper"

describe "paging the log screens", type: :request do
  let(:author) { create_user }
  let(:game) do
    g = create_game(:author => author, :is_draft => false)
    set_game_schedule!(g, :starts_at => 2.days.ago)
    g
  end
  let(:team) { create_team(:captain => create_user) }

  def sign_in(user)
    put login_path, :params => { :email => user.email, :password => "1234" }
  end

  before do
    create_game_passing(:level => create_level(:game => game), :team => team,
                        :game_run => game.current_run)
  end

  describe "the full log, paged by level" do
    def add_levels(count)
      count.times { |i| create_level(:game => game, :name => "Уровень #{i + 100}") }
    end

    it "shows only the first page of levels" do
      add_levels(25)
      sign_in(author)

      get show_full_log_path(:game_id => game.id)

      expect(response.body).to include("Уровень 100")
      expect(response.body).not_to include("Уровень 124")
    end

    it "shows the rest on page two" do
      add_levels(25)
      sign_in(author)

      get show_full_log_path(:game_id => game.id, :page => 2)

      expect(response.body).to include("Уровень 124")
      expect(response.body).not_to include("Уровень 100")
    end

    # THE frozen-scenario guard. features/logs/log.feature and
    # features/games/game_full_log.feature render this page; a pager on a
    # single-page log would change what they see.
    it "renders no pager at all when everything fits on one page" do
      add_levels(3)
      sign_in(author)

      get show_full_log_path(:game_id => game.id)

      expect(response.body).not_to include(I18n.t("shared.pager.next"))
      expect(response.body).not_to include(I18n.t("shared.pager.previous"))
    end
  end

  describe "the live channel, paged newest first" do
    def add_logs(count)
      level = create_level(:game => game)
      count.times do |i|
        create_log(:game => game, :level => level, :team => team,
                   :game_run => game.current_run,
                   :answer => "код#{i + 100}", :time => i.minutes.ago)
      end
    end

    # Newest first is what it ALREADY rendered: its comparator returned 1 when
    # left.time <= right.time. Moving the sort into SQL must not reverse a page
    # a frozen scenario reads.
    it "puts the newest answer first" do
      add_logs(3)
      sign_in(author)

      get show_live_channel_path(:game_id => game.id)

      expect(response.body.index("код100")).to be < response.body.index("код102")
    end

    it "pages at fifty" do
      add_logs(55)
      sign_in(author)

      get show_live_channel_path(:game_id => game.id)

      expect(response.body).to include(I18n.t("shared.pager.next"))
    end

    it "renders no pager for a quiet game" do
      add_logs(3)
      sign_in(author)

      get show_live_channel_path(:game_id => game.id)

      expect(response.body).not_to include(I18n.t("shared.pager.next"))
    end
  end

  # Same forgiving rule as ?run=: a stale or hand-edited URL shows page one
  # rather than an empty table or a 500.
  it "clamps an out-of-range page to the last one" do
    25.times { |i| create_level(:game => game, :name => "Уровень #{i + 100}") }
    sign_in(author)

    get show_full_log_path(:game_id => game.id, :page => 999)

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("Уровень 124")
  end

  it "clamps a malformed page to the first one" do
    25.times { |i| create_level(:game => game, :name => "Уровень #{i + 100}") }
    sign_in(author)

    get show_full_log_path(:game_id => game.id, :page => "не-число")

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("Уровень 100")
  end
end
