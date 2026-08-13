require "rails_helper"

# Task 2: an author picking files from the game's file library into a
# level's or hint's picker. The four traps this exists to catch:
#
#   1. game_file_ids must never reach Level#update/Hint#update directly --
#      the through-association's own writer strips the locale off every row.
#   2. the checkbox's pre-checked state must reflect what is REALLY attached
#      in the active tab's slot, not a hard-coded false.
#   3. a tab the author never opened this request must not be wiped: the
#      model cannot tell "unticked everything" from "this tab's picker was
#      never on the page" -- only the controller can, by treating an
#      entirely absent game_file_ids key as a no-op.
#   4. rendering the picker must never call web_variant/thumb_variant
#      (which GENERATE a variant on a miss) -- only the read-only
#      existing_* accessors, covered separately in the _file_table view spec
#      shape but exercised here too via a plain GET.
describe "the level/hint attachment picker", :type => :request do
  def login_as(user)
    post login_path, :params => { :email => user.email, :password => "1234" }
  end

  def checked?(body, file)
    Nokogiri::HTML(body).at_css("#game_file_#{file.id}")&.attr("checked").present?
  end

  let(:author) { create_user }
  let(:game)   { create_game(:author => author) }

  describe "on a level, single-locale game" do
    let(:level) { create_level(:game => game) }
    let(:a) { create_game_file(:game => game, :filename => "a.jpg") }
    let(:b) { create_game_file(:game => game, :filename => "b.jpg") }

    before { level; a; b; login_as(author) }

    it "attaches picked files on the primary tab to the neutral slot" do
      patch game_level_path(game, level),
            :params => { :level => { :name => level.name, :text => level.text,
                                      :game_file_ids => [ a.id.to_s, b.id.to_s ] },
                         :tab => game.primary_locale }

      expect(level.file_attachments.reload.where(:locale => nil).pluck(:game_file_id))
        .to contain_exactly(a.id, b.id)
    end

    it "removes a file that was ticked before and is not ticked now" do
      level.replace_attached_files([ a.id, b.id ], nil)

      patch game_level_path(game, level),
            :params => { :level => { :name => level.name, :text => level.text,
                                      :game_file_ids => [ a.id.to_s ] },
                         :tab => game.primary_locale }

      expect(level.file_attachments.reload.pluck(:game_file_id)).to eq([ a.id ])
    end

    it "clears the slot when every box is unticked, via the hidden fallback field alone" do
      # check_box_tag emits nothing for an unticked box -- what actually
      # reaches the controller here is exactly what _picker's hidden
      # fallback field posts on its own: level[game_file_ids] => [""].
      level.replace_attached_files([ a.id ], nil)

      patch game_level_path(game, level),
            :params => { :level => { :name => level.name, :text => level.text,
                                      :game_file_ids => [ "" ] },
                         :tab => game.primary_locale }

      expect(level.file_attachments.reload).to be_empty
    end

    it "round-trips the checked state: save, then reload the edit form" do
      patch game_level_path(game, level),
            :params => { :level => { :name => level.name, :text => level.text,
                                      :game_file_ids => [ a.id.to_s ] },
                         :tab => game.primary_locale }

      get edit_game_level_path(game, level)

      expect(checked?(response.body, a)).to be(true)
      expect(checked?(response.body, b)).to be(false)
    end

    # Trap 3: the request never carries the game_file_ids key at all -- a
    # renamed field, a stale bookmark, a form submitted by something other
    # than the real page. FileAttachable#replace_attached_files cannot tell
    # this apart from "nothing ticked" by itself; the controller's
    # apply_attached_files must not even call it.
    it "does NOT touch attachments when game_file_ids is absent from the request entirely" do
      level.replace_attached_files([ a.id, b.id ], nil)

      patch game_level_path(game, level),
            :params => { :level => { :name => "renamed, no attachments key at all" } }

      expect(level.reload.name).to eq("renamed, no attachments key at all")
      expect(level.file_attachments.reload.pluck(:game_file_id)).to contain_exactly(a.id, b.id)
    end

    it "refuses another author, and does not change attachments" do
      login_as(create_user)

      patch game_level_path(game, level),
            :params => { :level => { :name => level.name, :text => level.text,
                                      :game_file_ids => [ a.id.to_s ] },
                         :tab => game.primary_locale }

      expect(response).to have_http_status(:unauthorized)
      expect(level.file_attachments.reload).to be_empty
    end

    it "refuses a file id from another game's library, without raising" do
      foreign = create_game_file(:game => create_game)

      expect {
        patch game_level_path(game, level),
              :params => { :level => { :name => level.name, :text => level.text,
                                        :game_file_ids => [ foreign.id.to_s ] },
                           :tab => game.primary_locale }
      }.not_to raise_error

      expect(level.file_attachments.reload).to be_empty
    end
  end

  describe "on a level, multilingual game" do
    let(:game) do
      # A DRAFT with declared locales, not a published one: the publication
      # gate (declared_locales_are_translated_before_publication) only fires
      # when is_draft flips to false, so a draft can declare "ru en" with no
      # translations at all -- exactly what this picker spec needs, and
      # nothing this spec cares about tests publication.
      g = create_game(:author => author, :is_draft => true)
      g.available_locale_list = %w[ru en]
      g.save!
      g
    end
    let(:level) { create_level(:game => game) }
    let(:neutral_file) { create_game_file(:game => game, :filename => "neutral.jpg") }
    let(:english_file)  { create_game_file(:game => game, :filename => "english.jpg") }

    before do
      level.replace_attached_files([ neutral_file.id ], nil)
      login_as(author)
    end

    it "writes the non-primary tab's own slot, and leaves the neutral slot untouched" do
      patch game_level_path(game, level),
            :params => { :level => { :name => level.name, :text => level.text,
                                      :game_file_ids => [ english_file.id.to_s ] },
                         :tab => "en" }

      neutral = level.file_attachments.reload.where(:locale => nil)
      english = level.file_attachments.where(:locale => "en")

      expect(neutral.map(&:game_file_id)).to eq([ neutral_file.id ])
      expect(english.map(&:game_file_id)).to eq([ english_file.id ])
    end

    it "pre-checks only the active tab's own files, not the neutral strip's" do
      level.replace_attached_files([ english_file.id ], "en")

      get edit_game_level_path(game, level), :params => { :tab => "en" }

      expect(checked?(response.body, english_file)).to be(true)
      expect(checked?(response.body, neutral_file)).to be(false)
    end

    it "does not touch the English slot when only the primary tab is saved" do
      level.replace_attached_files([ english_file.id ], "en")

      patch game_level_path(game, level),
            :params => { :level => { :name => level.name, :text => level.text,
                                      :game_file_ids => [ neutral_file.id.to_s ] },
                         :tab => "ru" }

      english = level.file_attachments.reload.where(:locale => "en")
      expect(english.map(&:game_file_id)).to eq([ english_file.id ])
    end
  end

  describe "on a hint" do
    let(:level) { create_level(:game => game) }
    let(:hint)  { create_hint(:level => level) }
    let(:a) { create_game_file(:game => game, :filename => "a.jpg") }

    before { hint; a; login_as(author) }

    it "attaches a picked file to the hint's neutral slot on update" do
      patch game_level_hint_path(game, level, hint),
            :params => { :hint => { :text => hint.text, :delay_in_minutes => 1,
                                     :game_file_ids => [ a.id.to_s ] },
                         :tab => game.primary_locale }

      expect(hint.file_attachments.reload.where(:locale => nil).pluck(:game_file_id)).to eq([ a.id ])
    end

    it "attaches a picked file on create" do
      other_level = create_level(:game => game)

      post game_level_hints_path(game, other_level),
           :params => { :hint => { :text => "новая подсказка", :delay_in_minutes => 1,
                                    :game_file_ids => [ a.id.to_s ] },
                        :tab => game.primary_locale }

      created = other_level.hints.last
      expect(created.file_attachments.reload.where(:locale => nil).pluck(:game_file_id)).to eq([ a.id ])
    end

    it "does not touch attachments when game_file_ids is absent from an update" do
      hint.replace_attached_files([ a.id ], nil)

      patch game_level_hint_path(game, level, hint),
            :params => { :hint => { :text => "переименовано" } }

      expect(hint.reload.text).to eq("переименовано")
      expect(hint.file_attachments.reload.pluck(:game_file_id)).to eq([ a.id ])
    end
  end
end
