require "rails_helper"

describe User, "contact handle normalisation" do
  let(:user) { create_user }

  # Stored as a bare handle so the profile can render a working link and two
  # players who typed the same handle differently are stored identically.
  describe "#instagram" do
    {
      "@player"                       => "player",
      "https://instagram.com/player"  => "player",
      "http://instagram.com/player"   => "player",
      "www.instagram.com/player/"     => "player",
      "instagram.com/player"          => "player",
      "  player  "                    => "player",
      # Instagram's own profile URLs put the "@" after the host
      # (instagram.com/@player), not before it. Host must strip before "@",
      # or this would normalise to "@player" instead of "player".
      "instagram.com/@player"         => "player",
      "https://instagram.com/@player" => "player"
    }.each do |typed, stored|
      it "stores #{typed.inspect} as #{stored.inspect}" do
        user.update!(:instagram => typed)
        expect(user.reload.instagram).to eq(stored)
      end
    end

    it "stores an empty value as nil, so a cleared field is absent rather than blank" do
      user.update!(:instagram => "player")
      user.update!(:instagram => "")

      expect(user.reload.instagram).to be_nil
    end
  end

  describe "#telegram_id" do
    {
      "@player"               => "player",
      "https://t.me/player"   => "player",
      "t.me/player"           => "player",
      "telegram.me/player/"   => "player",
      "  player  "            => "player",
      # Same host-before-"@" hazard as Instagram, on both of Telegram's
      # recognised hosts.
      "t.me/@player"          => "player",
      "telegram.me/@player"   => "player"
    }.each do |typed, stored|
      it "stores #{typed.inspect} as #{stored.inspect}" do
        user.update!(:telegram_id => typed)
        expect(user.reload.telegram_id).to eq(stored)
      end
    end
  end

  # No format validation beyond normalisation: Instagram's and Telegram's own
  # handle rules change, and rejecting a valid handle is worse here than
  # storing an odd one. This is a contact note for a human, not an API key.
  it "accepts a handle it does not recognise rather than rejecting it" do
    user.update!(:instagram => "some.unusual_handle-99")

    expect(user.reload.instagram).to eq("some.unusual_handle-99")
  end

  describe "messenger availability" do
    it "defaults every flag to false" do
      expect(user.on_telegram).to be false
      expect(user.on_whatsapp).to be false
      expect(user.on_viber).to be false
      expect(user.on_signal).to be false
      expect(user.on_max).to be false
    end

    # Independent by design: a player may record a handle without ticking the
    # box ("that is my handle, but reach me on Signal"). Nothing derives one
    # from the other.
    it "does not tie the telegram flag to the telegram handle" do
      user.update!(:telegram_id => "player")

      expect(user.reload.on_telegram).to be false
    end
  end
end
