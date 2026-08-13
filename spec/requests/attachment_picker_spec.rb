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

  # Important 1 (Task 2 fix round): _picker.html.erb read
  # attachable.attached_file_ids_in_slot(slot) UNCONDITIONALLY, so a 422 --
  # the SAME request re-rendering :edit -- redisplayed the picker from the
  # database instead of from what the author just typed. Every other field on
  # this form (name, text) survives a 422 because it reads back from the
  # assigned-but-unsaved record; the picker had no equivalent until now.
  describe "a validation failure must not discard what the author just picked" do
    let(:level) { create_level(:game => game) }
    let(:a) { create_game_file(:game => game, :filename => "a.jpg") }
    let(:b) { create_game_file(:game => game, :filename => "b.jpg") }

    before do
      level.replace_attached_files([ a.id ], nil)
      login_as(author)
    end

    it "redisplays the just-picked files, not the saved slot, on a 422" do
      # The scenario the finding describes exactly: untick a, tick b,
      # accidentally blank the name.
      patch game_level_path(game, level),
            :params => { :level => { :name => "", :text => level.text,
                                      :game_file_ids => [ b.id.to_s ] },
                         :tab => game.primary_locale }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(checked?(response.body, a)).to be(false)
      expect(checked?(response.body, b)).to be(true)

      # And the 422 itself must not have written anything -- only a
      # subsequent successful save may change the stored slot.
      expect(level.file_attachments.reload.pluck(:game_file_id)).to eq([ a.id ])
    end

    it "falls back to the saved slot on an ordinary GET (no game_file_ids in params at all)" do
      get edit_game_level_path(game, level), :params => { :tab => game.primary_locale }

      expect(checked?(response.body, a)).to be(true)
      expect(checked?(response.body, b)).to be(false)
    end
  end

  # Important 2 (Task 2 fix round): no existing example drives the picker's
  # OWN <form> -- every request spec above hand-builds :params directly, and
  # the Cucumber step for attaching a file
  # (features/games/steps/game-files_steps.rb) calls FileAttachment.create!
  # directly. That leaves _picker.html.erb's own hidden fields -- the "tab"
  # field and the hidden empty-array fallback -- provably unexercised:
  # deleting either one from the view left the whole suite green (1692
  # examples, 0 failures). These examples GET the real edit page, read its
  # actual <form> inputs off the rendered DOM, and POST exactly that back --
  # so a missing hidden field shows up here as data landing in the wrong
  # slot, not as a build that stays green.
  describe "posting the picker's OWN rendered form, not hand-built params" do
    # A minimal HTML form serializer: every named input/textarea contributes
    # a (name, value) pair the way a real browser submission would -- an
    # unchecked checkbox or radio contributes nothing at all, matching HTML's
    # actual wire behaviour (this is exactly the property that makes the
    # hidden fallback field load-bearing in the first place). Rack::Utils
    # parses the resulting query string into the same nested-array shape
    # Rails' router would build from a real multipart/url-encoded POST, so
    # "level[game_file_ids][]=1&level[game_file_ids][]=2" round-trips into
    # {"level" => {"game_file_ids" => ["1", "2"]}} exactly as production does.
    def serialize_form(body)
      form = Nokogiri::HTML(body).at_css("form")
      pairs = []
      form.css("input[name], textarea[name]").each do |el|
        name = el["name"]
        if el.name == "textarea"
          pairs << [ name, el.text.to_s ]
          next
        end
        type = el["type"].to_s.downcase
        next if %w[submit button].include?(type)
        next if %w[checkbox radio].include?(type) && !el.key?("checked")
        pairs << [ name, el["value"].to_s ]
      end
      query = pairs.map { |k, v| "#{Rack::Utils.escape(k)}=#{Rack::Utils.escape(v)}" }.join("&")
      Rack::Utils.parse_nested_query(query)
    end

    let(:game) do
      g = create_game(:author => author, :is_draft => true)
      g.available_locale_list = %w[ru en]
      g.save!
      g
    end
    let(:level) { create_level(:game => game) }
    let(:neutral_file)  { create_game_file(:game => game, :filename => "neutral.jpg") }
    let(:english_file)  { create_game_file(:game => game, :filename => "english.jpg") }

    before do
      level.replace_attached_files([ neutral_file.id ], nil)
      login_as(author)
    end

    it "ticking a file on the real English tab writes only the English slot -- proves the tab field" do
      get edit_game_level_path(game, level), :params => { :tab => "en" }
      form_params = serialize_form(response.body)

      expect(form_params["tab"]).to eq("en"),
        "the rendered form carried tab=#{form_params["tab"].inspect}, not \"en\" -- " \
        "if _picker.html.erb's hidden_field_tag :tab were missing, this save would " \
        "silently land in the neutral slot every player sees"

      # english_file's box starts unticked (its slot is empty), so its id is
      # absent from the DOM entirely -- add it exactly as a click would.
      ids = Array(form_params.dig("level", "game_file_ids"))
      form_params["level"]["game_file_ids"] = ids + [ english_file.id.to_s ]

      patch game_level_path(game, level), :params => form_params

      neutral = level.file_attachments.reload.where(:locale => nil)
      english = level.file_attachments.where(:locale => "en")
      expect(neutral.map(&:game_file_id)).to eq([ neutral_file.id ])
      expect(english.map(&:game_file_id)).to eq([ english_file.id ])
    end

    it "unticking the real form's only checked box clears the slot -- proves the hidden fallback" do
      get edit_game_level_path(game, level), :params => { :tab => game.primary_locale }
      form_params = serialize_form(response.body)

      ids_before = Array(form_params.dig("level", "game_file_ids"))
      expect(ids_before).to include(neutral_file.id.to_s),
        "expected the rendered form to have neutral_file pre-checked; got #{ids_before.inspect}"

      # Simulate unticking neutral_file's box: drop ONLY its value, the way a
      # browser drops a checkbox's contribution when it is unchecked. What
      # survives is whatever the hidden fallback field alone contributes --
      # if it survives, remaining is [""], a non-empty array. If the fallback
      # field were missing (and no other box stayed checked), remaining is
      # genuinely empty, and the key must be REMOVED from the params hash
      # entirely to model that -- Rack::Test::Utils.build_nested_query pads
      # an empty ARRAY VALUE back into "level[game_file_ids][]=" (its own
      # convention for empty multi-selects), which would silently undo the
      # very thing this example exists to catch if left as [].
      remaining = ids_before - [ neutral_file.id.to_s ]
      if remaining.empty?
        form_params["level"].delete("game_file_ids")
      else
        form_params["level"]["game_file_ids"] = remaining
      end

      patch game_level_path(game, level), :params => form_params

      expect(level.file_attachments.reload).to be_empty
    end

    it "does not scale queries with library size when rendering the edit form" do
      one = count_queries {
        get edit_game_level_path(game, level), :params => { :tab => game.primary_locale }
      }

      3.times { |i| create_game_file(:game => game, :filename => "extra#{i}.jpg") }
      four = count_queries {
        get edit_game_level_path(game, level), :params => { :tab => game.primary_locale }
      }

      expect(four).to eq(one),
        "the edit page issued #{one} queries against a smaller library and #{four} " \
        "against a larger one -- _picker.html.erb's library query or _file_table is " \
        "reading per row"
    end
  end

  # Minor (Task 2 fix round): the mutation that proves existing_thumb_variant
  # (read-only) is used instead of thumb_variant (generates on a miss) only
  # went red because thumb_variant CRASHES on a fixture GameFile with no blob
  # -- not because anything asserted the render allocated no disk. This adds
  # the real assertion, mirroring the one file_deliveries_spec.rb already has
  # for the delivery route (design invariant I1): wipe every
  # ActiveStorage::VariantRecord, render the page, and prove the count stays
  # zero -- a crash would ALSO leave the count at zero without proving
  # anything, so this only means something alongside a 200 response.
  describe "rendering the picker never generates a variant (design invariant I1)" do
    let(:level) { create_level(:game => game) }

    it "creates no ActiveStorage::VariantRecord for a real, already-processed photo" do
      file = GameFileUpload.new(game, fixture_upload("photo.jpg"), author).call
      expect(file).to be_persisted
      expect(file.file.blob.variant_records.count).to be > 0

      ActiveStorage::VariantRecord.delete_all
      login_as(author)

      get edit_game_level_path(game, level), :params => { :tab => game.primary_locale }

      expect(response).to have_http_status(:ok)
      expect(ActiveStorage::VariantRecord.count).to eq(0)
    end
  end
end
