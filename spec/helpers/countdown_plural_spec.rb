require "rails_helper"

# This spec executes the REAL JavaScript that ships in
# app/views/shared/_countdown.html.erb, through node, rather than a Ruby
# reimplementation of the same rule.
#
# That is the whole point. The countdown is pluralised client-side: the
# template emits a three-element array per unit and a function mapping a
# number to one of its three indices, and the browser calls that function once
# a second. A Ruby mirror of the rule would pass happily while the shipped
# JavaScript stayed wrong -- it would be asserting that the spec agrees with
# itself. So the helper returns JavaScript source, and this spec runs it.
describe "the countdown's plural rule", :type => :helper do
  NODE = ["/usr/bin/nodejs", "/usr/bin/node", "node"].find do |candidate|
    system(candidate, "--version", :out => File::NULL, :err => File::NULL)
  end

  # Renders "%{n} %{word}" exactly the way _countdown.html.erb does at line 90:
  #   diff[i] + ' ' + lang[i][lang.plurar(diff[i])]
  def countdown_phrase(locale, unit, number)
    raise "no node binary found; this spec runs the emitted JavaScript" if NODE.nil?

    forms = I18n.with_locale(locale) { I18n.t("shared.countdown.#{unit}") }
    script = <<~JS
      var plurar = #{helper.countdown_plural_function(locale)};
      var forms = #{forms.to_json};
      var n = #{number};
      process.stdout.write(n + " " + forms[plurar(n)]);
    JS

    IO.popen([NODE, "-e", script], &:read)
  end

  # Polish is why this exists. The rule was East Slavic in every locale, and
  # its "one" slot fires for 21, 31, 101... -- which is right for Russian
  # ("21 год") and wrong for Polish, where only a bare 1 takes the singular.
  describe "Polish" do
    it "uses the singular only for a bare 1" do
      expect(countdown_phrase(:pl, "years", 1)).to eq("1 rok")
      expect(countdown_phrase(:pl, "days", 1)).to eq("1 dzień")
    end

    it "uses the few form for 2-4 and 22-24" do
      expect(countdown_phrase(:pl, "years", 2)).to eq("2 lata")
      expect(countdown_phrase(:pl, "years", 22)).to eq("22 lata")
    end

    # The bug this spec was written for.
    it "uses the many form for 21, 31 and 101, not the singular" do
      expect(countdown_phrase(:pl, "years", 21)).to eq("21 lat")
      expect(countdown_phrase(:pl, "years", 31)).to eq("31 lat")
      expect(countdown_phrase(:pl, "years", 101)).to eq("101 lat")
    end

    it "uses the many form for the teens and for 5 and up" do
      expect(countdown_phrase(:pl, "years", 5)).to eq("5 lat")
      expect(countdown_phrase(:pl, "years", 12)).to eq("12 lat")
      expect(countdown_phrase(:pl, "years", 112)).to eq("112 lat")
    end
  end

  # English is not what was reported, but it has carried the identical defect
  # since the file was written -- "21 year" -- because it was handed the same
  # Slavic rule. Same one-line fix, so it is pinned here too.
  describe "English" do
    it "uses the singular only for 1" do
      expect(countdown_phrase(:en, "years", 1)).to eq("1 year")
    end

    it "uses the plural for 21 and 101, not the singular" do
      expect(countdown_phrase(:en, "years", 21)).to eq("21 years")
      expect(countdown_phrase(:en, "years", 101)).to eq("101 years")
    end
  end

  # The locales that were already correct must stay correct: this change must
  # not "fix" Russian into saying "21 лет".
  describe "the East Slavic locales" do
    it "keeps Russian's singular for 1, 21 and 101" do
      expect(countdown_phrase(:ru, "years", 1)).to eq("1 год")
      expect(countdown_phrase(:ru, "years", 21)).to eq("21 год")
      expect(countdown_phrase(:ru, "years", 101)).to eq("101 год")
    end

    it "keeps Russian's few form for 2-4 and its many form for the teens" do
      expect(countdown_phrase(:ru, "years", 2)).to eq("2 года")
      expect(countdown_phrase(:ru, "years", 11)).to eq("11 лет")
      expect(countdown_phrase(:ru, "years", 25)).to eq("25 лет")
    end

    it "treats Belarusian and Ukrainian the same way" do
      expect(countdown_phrase(:be, "years", 21)).to eq("21 год")
      expect(countdown_phrase(:uk, "years", 21)).to eq("21 рік")
    end
  end

  # Turkish and Georgian put no plural agreement after a numeral at all, so
  # every slot holds the same word and any index is correct. Pinned so that a
  # future edit to their arrays does not quietly start depending on which slot
  # the rule picks.
  describe "the locales with no plural agreement after a numeral" do
    it "says the same thing for 1 and 21 in Turkish" do
      expect(countdown_phrase(:tr, "years", 1)).to eq("1 yıl")
      expect(countdown_phrase(:tr, "years", 21)).to eq("21 yıl")
    end

    it "says the same thing for 1 and 21 in Georgian" do
      expect(countdown_phrase(:ka, "years", 1)).to eq(countdown_phrase(:ka, "years", 21).sub("21", "1"))
    end
  end
end
