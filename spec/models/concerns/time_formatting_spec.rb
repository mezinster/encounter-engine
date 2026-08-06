require "rails_helper"

describe TimeFormatting do
  let(:subject) { Class.new { include TimeFormatting }.new }

  describe "#seconds_to_hms" do
    it "renders under a minute as zero-padded seconds" do
      expect(subject.seconds_to_hms(7)).to eq("00:00:07")
    end

    it "renders minutes and seconds" do
      expect(subject.seconds_to_hms(125)).to eq("00:02:05")
    end

    it "renders hours, minutes and seconds" do
      expect(subject.seconds_to_hms(3725)).to eq("01:02:05")
    end

    it "does not wrap past 24 hours" do
      expect(subject.seconds_to_hms(90_000)).to eq("25:00:00")
    end

    it "truncates a fractional interval rather than rounding it" do
      expect(subject.seconds_to_hms(59.9)).to eq("00:00:59")
    end

    it "renders zero" do
      expect(subject.seconds_to_hms(0)).to eq("00:00:00")
    end

    # Boundary inputs, one second below each hour rollover. An off-by-one in
    # the `% 3600` modulus (e.g. `% 3599`) agrees with the correct formula
    # everywhere except right at these points, so values like 7, 125, 3725
    # and 90_000 above cannot tell a correct modulus from a mutated one --
    # only a case that actually sits on the boundary can.
    it "renders the second just before the first hour rolls over" do
      expect(subject.seconds_to_hms(3599)).to eq("00:59:59")
    end

    it "renders the second just before the second hour rolls over" do
      expect(subject.seconds_to_hms(7199)).to eq("01:59:59")
    end

    it "renders the second just before 24 hours, still unwrapped" do
      expect(subject.seconds_to_hms(86_399)).to eq("23:59:59")
    end
  end

  describe "#hours_and_minutes" do
    it "splits an interval into whole hours and remaining whole minutes" do
      expect(subject.hours_and_minutes(3725)).to eq([1, 2])
    end

    it "returns zero hours for a short interval" do
      expect(subject.hours_and_minutes(125)).to eq([0, 2])
    end

    it "returns zeroes for an interval under a minute" do
      expect(subject.hours_and_minutes(30)).to eq([0, 0])
    end

    # Same `% 3600` structure as seconds_to_hms, and the same boundary blind
    # spot: an off-by-one modulus only disagrees with the correct formula at
    # the second just before an hour rolls over.
    it "returns 59 minutes at the boundary just before the first hour rolls over" do
      expect(subject.hours_and_minutes(3599)).to eq([0, 59])
    end

    it "returns 59 minutes at the boundary just before the second hour rolls over" do
      expect(subject.hours_and_minutes(7199)).to eq([1, 59])
    end
  end
end

describe GamePassing, "#time_at_level after the extraction" do
  it "still renders the elapsed time in the same HH:MM:SS format" do
    passing = create_game_passing
    passing.update_column(:current_level_entered_at, 3725.seconds.ago)

    expect(passing.time_at_level).to match(/\A01:02:0\d\z/)
  end
end
