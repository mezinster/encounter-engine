require "rails_helper"
require "open3"
require "json"

# The countdown is JavaScript, so this asserts on the emitted source rather than
# on a rendered number: the arithmetic that was wrong is right here in the
# template, and the frozen features that touch this partial assert the plural
# table's presence in that same source.
RSpec.describe "shared/_countdown", type: :view do
  let(:author) { create_user }
  let(:game)   { create_game(:author => author) }

  before do
    assign(:game, game)
    assign(:team, nil)
    assign(:current_user, author)
    view.define_singleton_method(:current_user) { author }
    view.define_singleton_method(:logged_in?)   { true }
  end

  # THE bug: days came from a calendar date subtraction while hours/minutes/
  # seconds came from the true interval, so "1 day" and "22 hours" were counted
  # from different things and printed together.
  it "derives every component from the interval, not from calendar fields" do
    render :partial => "shared/countdown"

    expect(rendered).not_to include("end.getDate()")
    expect(rendered).not_to include("end.getMonth()")
    expect(rendered).not_to include("end.getYear()")
  end

  it "reduces hours modulo 24, not 60" do
    render :partial => "shared/countdown"

    expect(rendered).not_to match(%r{hours\s*=\s*Math\.floor\([^)]*\)\s*%\s*60})
  end

  # features/games/enter-game-before-start.feature:23,42 assert this whole table
  # via have_text(:all, ...), which reaches inside the <script>. It must keep
  # rendering even though years and months are no longer computed.
  it "still renders the full plural table the frozen features assert" do
    render :partial => "shared/countdown"

    %w[years months days hours minutes seconds].each do |unit|
      expect(rendered).to include("#{unit}:")
    end
    expect(rendered).to include(I18n.t("shared.countdown.years").first)
    expect(rendered).to include(I18n.t("shared.countdown.months").first)
  end

  # The three examples above only assert on the *absence* of specific source
  # substrings ("end.getDate()", the "% 60" regex). That catches someone
  # pasting the old code back verbatim, but it proves nothing about the
  # arithmetic itself: a wrong divisor (e.g. total / 3600 for days) or a wrong
  # modulus base (e.g. % 12 for hours) contains neither forbidden substring
  # and would pass all three examples above while rendering a worse bug than
  # the one this file exists to fix.
  #
  # These examples extract the real `timeDifference` function and the real
  # `countdown_settings.lang` object out of the rendered <script>, run them
  # under Node, and assert on Node's actual return value -- not on the
  # template source.
  describe "timeDifference, evaluated under Node (not just grepped from source)" do
    NODE_BIN = begin
      Open3.capture2("node", "--version")
      "node"
    rescue Errno::ENOENT
      nil
    end

    # Pulls the real countdown_settings.lang object and the real
    # timeDifference function out of the rendered partial and runs
    # timeDifference(begin, end) inside a throwaway Node process, so the
    # assertions below exercise the exact code the browser would run.
    def time_difference_result(rendered, begin_iso, end_iso)
      lang_match = rendered.match(/lang:\s*\{(.*?)\n\s*\},\n\s*prefix:/m)
      raise "could not find countdown_settings.lang in the rendered partial" unless lang_match

      fn_match = rendered.match(/(var timeDifference = function\(begin, end\) \{.*?\n\s*\};)\n\s*var elem/m)
      raise "could not find timeDifference in the rendered partial" unless fn_match

      harness = <<~JS
        var countdown_settings = { lang: { #{lang_match[1]} } };
        #{fn_match[1]}
        console.log(JSON.stringify(timeDifference(new Date(#{begin_iso.to_json}), new Date(#{end_iso.to_json}))));
      JS

      stdout, stderr, status = Open3.capture3(NODE_BIN, "-e", harness)
      raise "node harness failed: #{stderr}" unless status.success?
      JSON.parse(stdout.strip)
    end

    before do
      skip("node is not on PATH; cannot evaluate timeDifference") unless NODE_BIN
    end

    it "renders the reported production case with no phantom day" do
      render :partial => "shared/countdown"

      result = time_difference_result(rendered, "2026-08-06T23:13:10", "2026-08-07T22:00:00")

      expect(result).to eq("22 часа 46 минут 50 секунд")
      expect(result).not_to include("день")
    end

    it "renders a 25-hour gap as 1 day 1 hour, not 1 day 25 hours" do
      render :partial => "shared/countdown"

      result = time_difference_result(rendered, "2026-01-01T00:00:00", "2026-01-02T01:00:00")

      expect(result).to eq("1 день 1 час")
    end

    it "renders a month-boundary gap in hours, with no phantom month or negative number" do
      render :partial => "shared/countdown"

      result = time_difference_result(rendered, "2026-08-31T23:00:00", "2026-09-01T01:00:00")

      expect(result).to eq("2 часа")
      expect(result).not_to include("месяц")
      expect(result).not_to match(/-\d/)
    end

    it "returns false when end is before begin" do
      render :partial => "shared/countdown"

      result = time_difference_result(rendered, "2026-01-02T00:00:00", "2026-01-01T00:00:00")

      expect(result).to eq(false)
    end
  end
end
