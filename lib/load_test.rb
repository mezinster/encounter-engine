# The guard is a separate, injectable check rather than a `Rails.env.production?`
# call inside the seeder, so it can be tested without pretending to be in
# production -- and so the console screen (task 5) enforces the same rule as the
# rake task rather than a lookalike.
module LoadTest
  class Refused < StandardError; end

  def self.guard!(cohort_id, environment: Rails.env)
    return unless environment.to_s == "production"

    # A blank id can never be confirmed, and this is checked BEFORE the
    # comparison rather than after. ENV["LOAD_TEST_CONFIRM"] is nil when unset
    # and the rake argument is nil when omitted, so `nil == nil` would read as
    # "confirmed" and authorise a nil-scoped sweep -- which matches the entire
    # cohort by e-mail domain -- against production with no confirmation at all.
    # An empty string pairs the same way.
    if cohort_id.to_s.empty?
      raise Refused, "a blank cohort id cannot be confirmed against production"
    end

    return if ENV["LOAD_TEST_CONFIRM"] == cohort_id

    raise Refused, "set LOAD_TEST_CONFIRM=#{cohort_id} to confirm this against production"
  end
end
