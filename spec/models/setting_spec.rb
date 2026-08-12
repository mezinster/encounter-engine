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

describe "string settings" do
  it "returns the shipped default when no row exists" do
    expect(Setting.list("allowed_extensions")).to eq(%w[jpg jpeg png gif heic pdf])
  end

  it "round-trips a list through the database" do
    Setting.put("allowed_extensions", %w[jpg pdf])

    expect(Setting.list("allowed_extensions")).to eq(%w[jpg pdf])
  end

  it "accepts a space-separated string, which is what the admin form submits" do
    Setting.put("allowed_extensions", "jpg  pdf\n png")

    expect(Setting.list("allowed_extensions")).to eq(%w[jpg pdf png])
  end

  it "lowercases and strips, so 'JPG ' and 'jpg' are one entry" do
    Setting.put("allowed_extensions", "JPG jpg  PDF ")

    expect(Setting.list("allowed_extensions")).to eq(%w[jpg pdf])
  end

  it "refuses a name that is not a registered string key" do
    expect { Setting.put("no_such_key", "x") }.to raise_error(ActiveRecord::RecordInvalid)
  end

  # STRING_DEFAULTS.freeze only freezes the hash, not the array inside it, and
  # Setting.list used to return that very array -- a caller mutating the
  # return value permanently widened the process-global shipped default. The
  # design's §4 invariant is that a superadmin may narrow the allowed set but
  # never widen it; a caller mutating the return value must not be able to
  # widen it either.
  it "does not let a caller mutate the shipped default through the returned value" do
    returned = Setting.list("allowed_extensions")
    returned << "svg"

    expect(Setting.list("allowed_extensions")).to eq(%w[jpg jpeg png gif heic pdf])
  end
end

describe "the admin settings page's key list" do
  # The page iterates Setting::DEFAULTS.keys and labels each with
  # t("admin.settings.names.<key>"). Adding a key here without its label in all
  # seven locales makes that page raise under raise_on_missing_translations.
  # Phase 1 kept Setting::DEFAULTS to the four rate limits and asserted so
  # here; Phase 2 (this change) is what moves the storage keys in, with their
  # labels, alongside the code that enforces them -- see "the storage keys
  # reaching the admin page" above for the pinned key list.
  it "still answers Setting.integer for a storage key" do
    expect(Setting.integer("game_quota_megabytes")).to eq(100)
  end

  it "does not require a numeric value for a string key" do
    expect { Setting.put("allowed_extensions", "jpg") }.not_to raise_error
  end
end

describe "integer settings, unchanged" do
  it "still returns the shipped default" do
    expect(Setting.integer("signup_max")).to eq(5)
  end

  it "still round-trips" do
    Setting.put("signup_max", 9)

    expect(Setting.integer("signup_max")).to eq(9)
  end

  it "still rejects a non-integer value for an integer key" do
    expect { Setting.put("signup_max", "abc") }.to raise_error(ActiveRecord::RecordInvalid)
  end

  it "still accepts zero, the documented off switch" do
    expect { Setting.put("signup_max", 0) }.not_to raise_error
  end
end

describe "the storage keys reaching the admin page" do
  it "offers all nine integer keys" do
    expect(Setting::DEFAULTS.keys).to eq(Setting::INTEGER_DEFAULTS.keys)
  end

  it "still offers the four rate limits first" do
    expect(Setting::DEFAULTS.keys.first(4))
      .to eq(%w[signup_max signup_window_seconds reset_max reset_window_seconds])
  end
end

describe "allowed_extensions entry format" do
  it "accepts ordinary extensions" do
    expect { Setting.put("allowed_extensions", "jpg png pdf") }.not_to raise_error
  end

  it "rejects an entry with a dot" do
    expect { Setting.put("allowed_extensions", ".jpg") }.to raise_error(ActiveRecord::RecordInvalid)
  end

  it "rejects an entry with a slash, which is how a path would arrive" do
    expect { Setting.put("allowed_extensions", "jpg ../etc") }.to raise_error(ActiveRecord::RecordInvalid)
  end

  it "rejects an absurdly long entry" do
    expect { Setting.put("allowed_extensions", "a" * 11) }.to raise_error(ActiveRecord::RecordInvalid)
  end

  it "rejects a numeric value, which normalise_list would otherwise stringify" do
    # Phase 1 finding: Setting.put("allowed_extensions", 123) silently stored "123".
    expect { Setting.put("allowed_extensions", 123) }.to raise_error(ActiveRecord::RecordInvalid)
  end
end

describe "integer settings, unchanged" do
  it "rejects nil for an integer key" do
    expect { Setting.put("signup_max", nil) }.to raise_error(ActiveRecord::RecordInvalid)
  end
end
