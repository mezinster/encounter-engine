require "rails_helper"

# The admin audit log renders its action column as
#
#   t("admin.audit.index.action.#{entry.action}", :default => entry.action)
#
# and that :default is load-bearing -- without it an action nobody anticipated
# would raise under the test environment's raise_on_missing_translations, and a
# superadmin would get a 500 on the log instead of a row. The cost is that a
# genuinely missing key does not fail anywhere: it renders as its own
# identifier, and `update_settings` sat in production reading exactly that
# until someone noticed it in a screenshot on 2026-08-10. Five more
# (pause, resume, move_team, reinstate_team, reset_clock) were missing beside
# it and nobody had noticed those at all.
#
# So the coverage has to be asserted here rather than inferred from a green
# view spec. This reads the action names out of the controllers instead of
# repeating them, because a hand-kept list in a spec drifts the same way the
# locale file did.
describe "admin audit action names" do
  # The three call shapes that write an audit row, all of which take the action
  # as their first argument: record_admin_action (the concern itself),
  # and interventions_controller's audit/audit_level wrappers around it.
  CALL = /(?:record_admin_action|audit|audit_level)\(\s*"([a-z_]+)"/

  def recorded_actions
    Dir[Rails.root.join("app/controllers/**/*.rb")]
      .flat_map { |path| File.read(path).scan(CALL) }
      .flatten
      .uniq
      .sort
  end

  it "finds the action names in the controllers at all" do
    # A guard on the guard: if the call shape is ever refactored, the regex
    # above quietly matches nothing and every example below passes vacuously.
    expect(recorded_actions.size).to be >= 20
    expect(recorded_actions).to include("update_settings", "pause", "delete_user")
  end

  I18n.available_locales.each do |locale|
    it "translates every recorded action in #{locale}" do
      missing = recorded_actions.reject do |action|
        I18n.exists?("admin.audit.index.action.#{action}", locale)
      end

      expect(missing).to be_empty,
        "no admin.audit.index.action.* entry in #{locale}.yml for: #{missing.join(', ')}"
    end
  end

  # The reverse direction. An action that is renamed in a controller leaves its
  # old translation behind, and nothing else would ever notice.
  it "has no translations for actions nothing records" do
    translated = I18n.t("admin.audit.index.action", :locale => :ru).keys.map(&:to_s).sort

    expect(translated - recorded_actions).to be_empty,
      "ru.yml translates actions no controller records: #{(translated - recorded_actions).join(', ')}"
  end
end
