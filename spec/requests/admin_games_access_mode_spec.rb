require "rails_helper"

# Covers app/views/admin/games/index.html.erb's status case, which used to
# have no :available branch and so fell into the bare `else` meant for
# :scheduled -- the exact model/view disagreement Game#status and
# count_by_status were built to prevent, just displaced into a view. See
# spec/models/game/access_mode_spec.rb and spec/models/game/status_spec.rb
# for the model-level ladder.
describe "the admin games index, for a gated game", type: :request do
  let(:author)     { create_user }
  let(:superadmin) { u = create_user; u.update!(:is_superadmin => true); u }

  # Same shape as spec/requests/admin_console_spec.rb.
  def sign_in(user)
    put login_path, :params => { :email => user.email, :password => "1234" }
  end

  # Literal Russian, not I18n.t: ru is the default locale in test, so an
  # assertion routed through I18n.t("admin.games.index.available") cannot
  # fail on a missing key -- it would just render "translation missing:
  # ..." and the include check would still (accidentally) tell you
  # something, but only by luck of what the failure string contains. Pinning
  # the literal string is what actually proves the label rendered.
  it "renders its own label, not the scheduled one, scoped to its own row" do
    available = create_game(:author => author, :is_draft => false, :access_mode => "pass_required")
    scheduled = create_game(:author => author, :is_draft => false)
    sign_in(superadmin)

    get admin_games_path

    doc = Nokogiri::HTML(response.body)
    row = doc.css("tr").find { |tr| tr.at_css("a[href='#{game_path(available)}']") }

    expect(row.text).to include("Доступна")
    expect(row.text).not_to include("Запланирована")

    other_row = doc.css("tr").find { |tr| tr.at_css("a[href='#{game_path(scheduled)}']") }
    expect(other_row.text).to include("Запланирована")
  end
end
