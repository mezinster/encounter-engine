require "rails_helper"
require "json"
require "shellwords"

# The play screen, measured in a real browser at real phone sizes.
#
# WHY THIS EXISTS. Neither suite can see layout. Capybara's rack_test driver
# parses no stylesheet and computes no style, so every assertion either suite
# can make about this screen is satisfied by markup that is entirely off the
# bottom of the phone. That is not hypothetical: `.page { min-height: 100vh }`
# silently clamped `.page--focused { height: 100dvh }` for months, the play
# shell computed 844px on a phone with 680px of visible viewport, and the
# submit button sat 84-128px below the screen -- through a green suite, on
# production, until someone sent in a photograph of their phone.
#
# WHY IT IS OPT-IN. It needs a browser binary CI does not install
# (config.filter_run_excluding :layout in spec/rails_helper.rb). Excluded
# rather than skipped, so it is never reported as a pending pass; and when it
# is asked to run, a missing browser RAISES rather than skipping -- the same
# rule the countdown specs follow.
#
# WHAT IT PINS, and what it deliberately does not. It pins the properties that
# survive a redesign: nothing scrolls inside anything else, nothing overflows
# sideways, and the controls a player needs are hit-testable rather than merely
# present. It does NOT pin heights. A number here would fail on the next
# harmless copy change and teach everyone to update it without looking.
# Namespaced, NOT constants in the describe block. Ruby's lexical scope puts a
# constant assigned inside `describe` onto Object, and this file is LOADED on
# every ordinary rspec run -- only its examples are filtered out -- so a name as
# generic as VIEWPORTS would collide with any other file that wanted it, warn
# about an already-initialized constant, and clobber one of the two. Locals
# would not work either: `def` bodies below do not close over them.
module PlayScreenLayoutHarness
  # 390x680: an iPhone 14 Pro is 390x844, and Safari's chrome leaves ~680.
  # Measuring at 844 is what let the original bug through -- see the note in
  # CLAUDE.md. 375x553 is an iPhone SE, the tightest real case. 1280x800 is
  # the two-column desktop shell, which the same stylesheet has to serve.
  VIEWPORTS = { "iPhone 14 Pro (visible)" => [ 390, 680 ],
                "iPhone SE (visible)"     => [ 375, 553 ],
                "desktop"                 => [ 1280, 800 ] }.freeze

  CHROME_GLOB = File.expand_path(
    "~/.cache/ms-playwright/chromium_headless_shell-*/chrome-headless-shell-linux64/chrome-headless-shell"
  )
end

describe "the play screen, measured", :layout, type: :request do

  # The full chromium build clamps windows to 500px wide, which silently turns
  # every phone measurement into a 500px one; headless_shell honours narrow
  # sizes. Raise rather than skip: a measurement that quietly did not happen is
  # worse than no measurement, because it reports as a pass.
  def chrome
    @chrome ||= Dir.glob(PlayScreenLayoutHarness::CHROME_GLOB).max ||
      raise(<<~MSG)
        No chrome-headless-shell found at #{PlayScreenLayoutHarness::CHROME_GLOB}

        Install it with:  npx playwright install chromium
        The full `chromium-*/chrome-linux64/chrome` build is NOT a substitute --
        it clamps the window to 500px wide, so every phone size measures as 500.
      MSG
  end

  # Rewrites the stylesheet links AND the attachment images to absolute file://
  # paths so the page can be opened straight off disk. A static HTTP server
  # would work too and is what earlier ad-hoc runs used; this removes a moving
  # part (a port, a process to reap) from something that has to be trustworthy
  # to be worth running.
  #
  # The images matter and were missed the first time round. Left as
  # `/games/1/files/1/web`, they resolve against file:// to `file:///games/...`
  # and never load -- so this harness measured two BROKEN images while claiming
  # to measure photographs, which is the entire content class it exists for.
  # They occupied the right 96x96 anyway, but only because .attachment-image
  # hard-codes width and height; the day that becomes an intrinsic size, a
  # harness that silently measures nothing would have gone on passing.
  # `imagesLoaded` in the probe is what stops that happening again.
  def measure(html, width, height, script)
    page = html.gsub(%r{href="/(stylesheets/[^"]+)"}) do
      %(href="file://#{Rails.root.join('public', Regexp.last_match(1))}")
    end
    # The delivery route is dynamic (variant, authorization, streaming); none of
    # that is layout. What layout needs is a real decoded image of a real size,
    # which is the fixture the upload was built from in the first place.
    photo = Rails.root.join("spec/fixtures/files/photo.jpg")
    page = page.gsub(%r{src="/games/\d+/files/\d+/\w+"}, %(src="file://#{photo}"))
    page = page.sub("</body>", <<~PROBE + "</body>")
      <script>
      window.addEventListener("load", function () {
        #{script}
        var pre = document.createElement("pre");
        pre.textContent = "RESULT=" + JSON.stringify(RESULT);
        document.body.appendChild(pre);
      });
      </script>
    PROBE

    file = Rails.root.join("tmp", "play-screen-measure.html")
    FileUtils.mkdir_p(file.dirname)
    File.write(file, page)

    dom = `#{Shellwords.join([
      chrome, "--no-sandbox", "--hide-scrollbars", "--allow-file-access-from-files",
      "--window-size=#{width},#{height}", "--virtual-time-budget=4000",
      "--dump-dom", "file://#{file}"
    ])} 2>/dev/null`

    # tail: the probe's own source contains the literal "RESULT=" too, and it
    # is in the dumped DOM ahead of the value.
    json = dom.scan(/RESULT=(\{.*?\})<\/pre>/m).last&.first ||
      raise("the browser produced no measurement; dumped DOM was:\n#{dom[0, 2000]}")
    JSON.parse(json)
  end

  PROBE_SCRIPT = <<~JS
    function hit(sel) {
      var e = document.querySelector(sel);
      if (!e) return "ABSENT";

      // Rendered at all? checkVisibility catches display:none, visibility:
      // hidden, content-visibility and opacity:0 -- none of which the point
      // test below can tell apart from "painted and pressable". This used to
      // rely on the point test alone plus an `at.contains(e)` fallback, and
      // that combination reported OK for a `visibility: hidden` control:
      // elementFromPoint returns the nearest painted ANCESTOR (.playbar), the
      // fallback accepted an ancestor, and a button nobody could see passed.
      // Verified by injecting `.btn--go { visibility: hidden !important }`.
      if (!e.checkVisibility({ checkVisibilityCSS: true, checkOpacity: true })) return "NOT-VISIBLE";

      var r = e.getBoundingClientRect();
      if (r.width === 0 || r.height === 0) return "ZERO-SIZE";

      var at = document.elementFromPoint(r.left + r.width / 2, r.top + r.height / 2);
      if (!at) return "NOT-IN-VIEWPORT";
      // e === at, or a descendant of e was hit (a button's inner text node's
      // parent, a label's input). An ANCESTOR is deliberately NOT accepted --
      // that is the signature of e not being painted where it claims to be.
      return (at === e || e.contains(at)) ? "OK" : "COVERED-BY-" + at.tagName;
    }
    function scrolls(sel) {
      var e = document.querySelector(sel);
      return e ? (e.scrollHeight - e.clientHeight > 1) : false;
    }
    var RESULT = {
      submitAtTop: hit(".btn--go"),
      hOverflow: document.documentElement.scrollWidth - document.documentElement.clientWidth,
      innerScroll: [".main", ".play-body", ".playbar"].filter(scrolls),
      // Proves the photographs this screen was redesigned around are really
      // being rendered and measured, rather than being broken <img>s holding
      // a hard-coded box. naturalWidth is 0 for an image that failed to load.
      images: Array.prototype.map.call(
        document.querySelectorAll(".attachment-image"),
        function (i) { return i.naturalWidth > 0 ? Math.round(i.getBoundingClientRect().height) : "BROKEN"; }
      )
    };
    window.scrollTo(0, document.documentElement.scrollHeight);
    RESULT.submitAtBottom = hit(".btn--go");
    RESULT.exitAtBottom = hit(".play-exit .btn");
    RESULT.lastOptionAtBottom = hit(".quiz-option:last-of-type");
    // The sticky bar must come to rest ON the bottom edge at maximum scroll,
    // not short of it: .main's bottom padding sits inside the bar's containing
    // block, and a sticky box stops at the end of that block, which left a
    // 23px strip of page background under the bar at the end of the scroll.
    var bar = document.querySelector(".playbar").getBoundingClientRect();
    RESULT.barGapAtBottom = Math.round(window.innerHeight - bar.bottom);
  JS

  # The worst real content state: a quiz whose options run past one screen, a
  # photograph on the task AND on a fired hint (a hint's strip is the one an
  # earlier design never accounted for), and the captain's exit button present.
  let(:page_html) do
    author = create_user
    game = create_game(:author => author, :name => "Викторина")
    set_game_schedule!(game, :starts_at => 1.hour.ago)

    level = create_quiz_level(:game => game, :name => "Вопрос 2",
                              :text => "Что, по словам художника-постановщика " \
                                       "«Матрицы», изображает знаменитый зелёный код фильма?")
    question = create_question(:level => level)
    4.times { |i| create_option(:question => question, :text => "Вариант ответа номер #{i + 1}", :is_correct => i.zero?) }

    hint = create_hint(:level => level, :delay => 0,
                       :text => "А может быть вы не посмотрели вот сюда: LN01TP ?")

    level_file = GameFileUpload.new(game, fixture_upload("photo.jpg"), author).call
    hint_file  = GameFileUpload.new(game, fixture_upload("photo.jpg"), author).call
    raise "upload failed: #{level_file.errors.full_messages}#{hint_file.errors.full_messages}" unless
      level_file.persisted? && hint_file.persisted?
    level.replace_attached_files([ level_file.id ], nil)
    hint.replace_attached_files([ hint_file.id ], nil)

    player = create_user
    team = create_team(:captain => player)
    create_game_entry(:game => game, :team => team)
    create_game_passing(:level => level, :team => team)

    put login_path, :params => { :email => player.email, :password => "1234" }
    get show_current_level_path(:game_id => game.id)
    expect(response).to have_http_status(:ok)
    response.body
  end

  PlayScreenLayoutHarness::VIEWPORTS.each do |name, (width, height)|
    context "at #{width}x#{height} -- #{name}" do
      let(:m) { measure(page_html, width, height, PROBE_SCRIPT) }

      # The one that shipped broken. "Present in the DOM" is what both suites
      # can check and is not the same claim at all.
      it "puts the submit button where it can be pressed, at both ends of the scroll" do
        expect(m["submitAtTop"]).to eq("OK")
        expect(m["submitAtBottom"]).to eq("OK")
      end

      it "leaves the captain's exit and the last answer reachable" do
        expect(m["exitAtBottom"]).to eq("OK")
        expect(m["lastOptionAtBottom"]).to eq("OK")
      end

      # The design property, not a measurement: ONE scroll. Three regions used
      # to be scrollports of their own, each smaller than its content -- a
      # 170px window on 479px of question, a 76px window on 228px of options.
      # If any of them starts scrolling again, the squeeze is back.
      it "scrolls the page and nothing inside it" do
        expect(m["innerScroll"]).to eq([])
      end

      it "does not overflow sideways" do
        expect(m["hOverflow"]).to eq(0)
      end

      # Without this the harness happily measures broken <img>s that occupy the
      # right box only because .attachment-image hard-codes 96x96 -- which is
      # what it was doing until this example existed.
      it "really renders the photographs it claims to be measuring" do
        expect(m["images"]).to eq([ 96, 96 ])
      end

      # Phone widths only. From 52rem up the bar is a panel in the right-hand
      # column and deliberately not sticky at all, so "flush with the bottom
      # edge" is not a claim about it -- asserting it there would pin the
      # length of the left column, which is content.
      if width < 832
        # Sticky, and flush with the bottom edge at maximum scroll rather than
        # stopping short of it with page background showing underneath.
        it "rests the bar on the bottom edge at maximum scroll" do
          expect(m["barGapAtBottom"]).to eq(0)
        end
      end
    end
  end
end
