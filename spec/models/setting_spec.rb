require "rails_helper"

describe Setting do
  it "falls back to the in-code default when no row exists" do
    expect(Setting.count).to eq(0)
    expect(Setting.integer("signup_max")).to eq(Setting::DEFAULTS.fetch("signup_max"))
  end

  it "prefers a stored value over the default" do
    Setting.put("signup_max", 42)
    expect(Setting.integer("signup_max")).to eq(42)
  end

  it "updates in place rather than adding a second row for the same name" do
    Setting.put("signup_max", 42)
    Setting.put("signup_max", 7)

    expect(Setting.where(:name => "signup_max").count).to eq(1)
    expect(Setting.integer("signup_max")).to eq(7)
  end

  # Zero is the documented "off" value, so it must survive validation -- a
  # greater_than(0) rule here would remove the operator's ability to disable a
  # limit without a deploy, which is the whole point of the table.
  it "accepts zero" do
    Setting.put("reset_max", 0)
    expect(Setting.integer("reset_max")).to eq(0)
  end

  it "refuses a negative value" do
    expect { Setting.put("reset_max", -1) }.to raise_error(ActiveRecord::RecordInvalid)
  end

  # Without this an admin form typo creates a row nothing reads, and the limit
  # silently stays at its default while the console shows the new number.
  it "refuses a name that is not a known setting" do
    expect { Setting.put("signup_maxx", 5) }.to raise_error(ActiveRecord::RecordInvalid)
  end
end
