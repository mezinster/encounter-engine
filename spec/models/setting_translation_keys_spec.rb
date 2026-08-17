require "rails_helper"

describe Setting, "translation keys" do
  it "defaults the model to Claude Opus 5 with no row present" do
    expect(Setting.enum("translation_model")).to eq("claude-opus-5")
  end

  it "stores an allowed model" do
    Setting.put("translation_model", "claude-sonnet-5")

    expect(Setting.enum("translation_model")).to eq("claude-sonnet-5")
  end

  # An allow-list, not free text -- the same shape as allowed_extensions, which
  # a superadmin may narrow but must not be able to widen into something
  # dangerous. Here the hazard is a typo'd model ID that 404s every call of a
  # run, or a model nobody costed.
  it "refuses a model that is not on the allow-list" do
    expect { Setting.put("translation_model", "gpt-4") }
      .to raise_error(ActiveRecord::RecordInvalid)

    expect(Setting.enum("translation_model")).to eq("claude-opus-5")
  end

  it "refuses a model ID that only looks plausible" do
    expect { Setting.put("translation_model", "claude-opus-5-20260101") }
      .to raise_error(ActiveRecord::RecordInvalid)
  end

  it "caps the fields one run may translate" do
    expect(Setting.integer("translation_max_fields_per_run")).to eq(5_000)

    Setting.put("translation_max_fields_per_run", 50)
    expect(Setting.integer("translation_max_fields_per_run")).to eq(50)
  end
end
