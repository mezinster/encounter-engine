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
  end
end

describe GamePassing, "#time_at_level after the extraction" do
  it "still renders the elapsed time in the same HH:MM:SS format" do
    passing = create_game_passing
    passing.update_column(:current_level_entered_at, 3725.seconds.ago)

    expect(passing.time_at_level).to match(/\A01:02:0\d\z/)
  end
end
