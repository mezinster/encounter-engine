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
describe "the play screen, measured", :layout, type: :request do
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

  # The full chromium build clamps windows to 500px wide, which silently turns
  # every phone measurement into a 500px one; headless_shell honours narrow
  # sizes. Raise rather than skip: a measurement that quietly did not happen is
  # worse than no measurement, because it reports as a pass.
  def chrome
    @chrome ||= Dir.glob(CHROME_GLOB).max ||
      raise(<<~MSG)
        No chrome-headless-shell found at #{CHROME_GLOB}

        Install it with:  npx playwright install chromium
        The full `chromium-*/chrome-linux64/chrome` build is NOT a substitute --
        it clamps the window to 500px wide, so every phone size measures as 500.
      MSG
  end

  # Rewrites the stylesheet links to absolute file:// paths so the page can be
  # opened straight off disk. A static HTTP server would work too and is what
  # earlier ad-hoc runs used; this removes a moving part (a port, a process to
  # reap) from something that has to be trustworthy to be worth running.
  def measure(html, width, height, script)
    page = html.gsub(%r{href="/(stylesheets/[^"]+)"}) do
      %(href="file://#{Rails.root.join('public', Regexp.last_match(1))}")
    end
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
      var r = e.getBoundingClientRect();
      var at = document.elementFromPoint(r.left + r.width / 2, r.top + r.height / 2);
      if (!at) return "NOT-IN-VIEWPORT";
      return (at === e || e.contains(at) || at.contains(e)) ? "OK" : "COVERED-BY-" + at.tagName;
    }
    function scrolls(sel) {
      var e = document.querySelector(sel);
      return e ? (e.scrollHeight - e.clientHeight > 1) : false;
    }
    var RESULT = {
      submitAtTop: hit(".btn--go"),
      hOverflow: document.documentElement.scrollWidth - document.documentElement.clientWidth,
      innerScroll: [".main", ".play-body", ".playbar"].filter(scrolls)
    };
    window.scrollTo(0, document.documentElement.scrollHeight);
    RESULT.submitAtBottom = hit(".btn--go");
    RESULT.exitAtBottom = hit(".play-exit .btn");
    RESULT.lastOptionAtBottom = hit(".quiz-option:last-of-type");
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

  VIEWPORTS.each do |name, (width, height)|
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
    end
  end
end
