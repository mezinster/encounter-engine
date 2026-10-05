require "rails_helper"

# The minor findings from the 2026-10-05 superadmin-console review (PR #191),
# one example each.
describe "superadmin console polish", type: :request do
  let(:superadmin) { u = create_user; u.update!(:is_superadmin => true); u }
  let(:author)     { create_user }

  def sign_in(user)
    put login_path, :params => { :email => user.email, :password => "1234" }
  end

  def doc
    Nokogiri::HTML(response.body)
  end

  describe "tab titles" do
    # Several game pages open in tabs used to read the same «Администрирование».
    it "names the game on its admin page" do
      game = create_game(:author => author, :name => "Ночной Бишкек")
      sign_in(superadmin)
      get admin_game_path(game)

      expect(doc.at_css("title").text).to include("Ночной Бишкек")
    end

    it "names the game on its applications page" do
      game = create_game(:author => author, :name => "Ночной Бишкек")
      sign_in(superadmin)
      get admin_game_entries_path(game)

      expect(doc.at_css("title").text).to include("Ночной Бишкек")
    end
  end

  describe "the teams list" do
    # Members past the third used to exist only as <option>s in the captain
    # picker, which a browser's find-in-page does not search.
    it "keeps every member's name in the members cell, the rest behind a disclosure" do
      team = create_team(:captain => create_user)
      5.times { team.members << create_user }
      sign_in(superadmin)
      get admin_teams_path

      row  = doc.css("tbody tr").find { |tr| tr.text.include?(team.name) }
      cell = row.at_css("td.members")
      team.members.each { |m| expect(cell.text).to include(m.nickname) }
      more = cell.at_css("details.members-more")
      expect(more).not_to be_nil
      expect(more["open"]).to be_nil
      expect(more.at_css("summary").text.strip).to eq("и ещё #{team.members.count - 3}")
    end

    it "labels the captain picker" do
      team = create_team(:captain => create_user)
      sign_in(superadmin)
      get admin_teams_path

      select = doc.at_css("select[name='member_id']")
      label  = doc.at_css("label[for='#{select['id']}']")
      expect(label.text.strip).to eq("Капитан")
    end
  end

  describe "the user page" do
    # #revoke refuses yourself, so the button could only ever produce an alert.
    it "does not offer you the revoke of your own admin rights" do
      sign_in(superadmin)
      get admin_user_path(superadmin)

      expect(response.body).not_to include(revoke_admin_user_path(superadmin))
    end

    it "still offers revoke on another superadmin's page" do
      other = create_user
      other.update!(:is_superadmin => true)
      sign_in(superadmin)
      get admin_user_path(other)

      expect(doc.at_css("form[action='#{revoke_admin_user_path(other)}']")).not_to be_nil
    end

    it "labels the move-team picker" do
      target = create_user
      create_team(:captain => create_user)
      sign_in(superadmin)
      get admin_user_path(target)

      select = doc.at_css("select[name='team_id']")
      label  = doc.at_css("label[for='#{select['id']}']")
      expect(label.text.strip).to eq("Команда")
    end

    it "renders no role line for a user with no roles" do
      sign_in(superadmin)
      get admin_user_path(create_user)

      expect(doc.at_css(".admin-user-roles")).to be_nil
    end
  end
end
