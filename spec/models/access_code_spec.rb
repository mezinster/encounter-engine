require "rails_helper"

describe AccessCode do
  let(:game) { create_game(:is_draft => false, :access_mode => "pass_required") }

  describe ".normalize" do
    it "upcases" do
      expect(AccessCode.normalize("abcde12345")).to eq("ABCDE12345")
    end

    it "strips spaces and dashes" do
      expect(AccessCode.normalize(" ABCDE-12345 ")).to eq("ABCDE12345")
    end

    # Crockford excludes I, L, O and U from the OUTPUT alphabet precisely so
    # they can be accepted as INPUT aliases. A customer types what they see.
    it "maps the confusables the alphabet excludes" do
      expect(AccessCode.normalize("OIL")).to eq("011")
    end

    it "is nil-safe" do
      expect(AccessCode.normalize(nil)).to eq("")
    end
  end

  describe ".digest" do
    it "digests the normalised form, so a typed O matches a printed 0" do
      expect(AccessCode.digest("o1-234")).to eq(AccessCode.digest("01234"))
    end

    it "differs for different codes" do
      expect(AccessCode.digest("ABCDE12345")).not_to eq(AccessCode.digest("ABCDE12346"))
    end

    # U is excluded from the alphabet precisely because it is confusable with
    # V -- on a card, in handwriting, and in several fonts a client is likely
    # to print with. Digest equality is the property redemption actually
    # depends on, so this asserts on digest, not only normalize; a code typed
    # with U must resolve to the same row as the same code printed with V,
    # never to whatever "1" happens to collide with.
    it "digests a typed U identically to a printed V, not to 1" do
      expect(AccessCode.digest("U2345ABCDE")).to eq(AccessCode.digest("V2345ABCDE"))
      expect(AccessCode.normalize("U2345ABCDE")).to eq("V2345ABCDE")
    end
  end

  describe ".generate_batch!" do
    it "mints the requested number of codes sharing one batch_key" do
      key, raws = AccessCode.generate_batch!(:game => game, :count => 3, :issued_by => create_user)

      expect(raws.length).to eq(3)
      expect(AccessCode.where(:batch_key => key).count).to eq(3)
    end

    it "returns raw codes that are ten characters of the alphabet" do
      _key, raws = AccessCode.generate_batch!(:game => game, :count => 5, :issued_by => create_user)

      raws.each do |raw|
        expect(raw.length).to eq(10)
        expect(raw.chars.all? { |c| AccessCode::ALPHABET.include?(c) }).to be true
      end
    end

    it "stores no raw code anywhere" do
      _key, raws = AccessCode.generate_batch!(:game => game, :count => 1, :issued_by => create_user)

      expect(AccessCode.first.attributes.values.map(&:to_s)).not_to include(raws.first)
    end

    it "mints distinct codes" do
      _key, raws = AccessCode.generate_batch!(:game => game, :count => 20, :issued_by => create_user)

      expect(raws.uniq.length).to eq(20)
    end

    it "carries the batch expiry onto every code" do
      when_ = 3.days.from_now
      _key, _raws = AccessCode.generate_batch!(:game => game, :count => 2,
                                               :issued_by => create_user, :expires_at => when_)

      expect(AccessCode.all.map(&:expires_at).compact.length).to eq(2)
    end
  end

  describe ".find_by_code" do
    it "finds a minted code" do
      _key, raws = AccessCode.generate_batch!(:game => game, :count => 1, :issued_by => create_user)

      expect(AccessCode.find_by_code(raws.first)).to eq(AccessCode.first)
    end

    it "finds it when typed with confusables and a dash" do
      _key, raws = AccessCode.generate_batch!(:game => game, :count => 1, :issued_by => create_user)
      typed = raws.first.dup
      typed[0] = "O" if typed[0] == "0"
      typed = typed.insert(5, "-").downcase

      expect(AccessCode.find_by_code(typed)).to eq(AccessCode.first)
    end

    it "returns nil for an unknown code" do
      AccessCode.generate_batch!(:game => game, :count => 1, :issued_by => create_user)

      expect(AccessCode.find_by_code("ZZZZZZZZZZ")).to be_nil
    end

    # A blank input must never resolve to a row, even one whose digest column
    # is somehow blank -- the same failure User.find_by_reset_token guards.
    it "returns nil for a blank input" do
      expect(AccessCode.find_by_code("")).to be_nil
      expect(AccessCode.find_by_code(nil)).to be_nil
    end
  end

  describe "#redeemable? and #state" do
    def code
      AccessCode.generate_batch!(:game => game, :count => 1, :issued_by => create_user)
      AccessCode.first
    end

    it "is redeemable when fresh" do
      c = code
      expect(c.redeemable?).to be true
      expect(c.state).to eq(:outstanding)
    end

    it "is not redeemable once revoked" do
      c = code
      c.update!(:revoked_at => Time.now)
      expect(c.redeemable?).to be false
      expect(c.state).to eq(:revoked)
    end

    it "is not redeemable once redeemed" do
      c = code
      c.update!(:redeemed_at => Time.now)
      expect(c.redeemable?).to be false
      expect(c.state).to eq(:redeemed)
    end

    it "is not redeemable once expired" do
      c = code
      c.update!(:expires_at => 1.minute.ago)
      expect(c.redeemable?).to be false
      expect(c.state).to eq(:expired)
    end

    it "is redeemable with an expiry still in the future" do
      c = code
      c.update!(:expires_at => 1.day.from_now)
      expect(c.redeemable?).to be true
    end

    # Redemption wins over expiry in the report, because a redeemed code has
    # already produced a pass and the customer's run is not the code's business.
    it "reports :redeemed even if its expiry has since passed" do
      c = code
      c.update!(:redeemed_at => 2.days.ago, :expires_at => 1.day.ago)
      expect(c.state).to eq(:redeemed)
    end
  end

  it "refuses a code on a game that is not gated" do
    scheduled = create_game(:is_draft => false)

    expect {
      AccessCode.generate_batch!(:game => scheduled, :count => 1, :issued_by => create_user)
    }.to raise_error(ActiveRecord::RecordInvalid)
  end
end
