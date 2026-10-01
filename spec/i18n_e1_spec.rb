require "rails_helper"

describe "E1 locale fixes" do
  it "abbreviates Belarusian months in lowercase" do
    I18n.with_locale(:be) { expect(I18n.l(Time.utc(2050, 10, 12, 21), :format => :home_row)).to eq("12 кас, 21:00") }
  end

  it "has no index.index.title left in any locale" do
    Dir[Rails.root.join("config/locales/*.yml")].each do |file|
      locale = File.basename(file, ".yml")
      data = YAML.unsafe_load_file(file)[locale]
      expect(data.dig("index", "index", "title")).to be_nil, file
    end
  end

  it "reports an open-run problem with the team limit as a sentence, not a column name" do
    run = GameRun.new(:game => create_game, :ordinal => 2, :starts_at => 1.day.from_now, :max_team_number => nil)
    run.valid?(:open)
    expect(run.errors.full_messages.join(" ")).not_to match(/Max team number|Ordinal/)
    expect(run.errors.full_messages).to include("Вы не указали количество команд")
  end
end
