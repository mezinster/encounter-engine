# spec/support/layout_measurement.rb
#
# Drives a real headless browser at a fixed viewport and returns whatever the
# probe script assigns to RESULT.
#
# Extracted from spec/layout/play_screen_layout_spec.rb, which is where all of
# this was born and where the reasoning in the comments below was learned. It
# lives here now because more than one screen needs measuring, and the play
# screen has no claim on the mechanism. Nothing about the behaviour changed in
# the move except `tmp_name`, so two specs cannot fight over one scratch file.
#
# NOT auto-required: spec/rails_helper.rb deliberately leaves the
# `Rails.root.glob('spec/support/**/*.rb')` line commented out and requires
# support files one by one instead. Use `require_relative` from the spec that
# needs this, the same way spec/support/query_counter.rb is pulled in.
require "json"
require "shellwords"

module LayoutMeasurement
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
  def measure(html, width, height, script, tmp_name: "layout-measure.html")
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

    file = Rails.root.join("tmp", tmp_name)
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
end
