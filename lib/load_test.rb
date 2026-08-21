# The guard is a separate, injectable check rather than a `Rails.env.production?`
# call inside the seeder, so it can be tested without pretending to be in
# production -- and so the console screen (task 5) enforces the same rule as the
# rake task rather than a lookalike.
module LoadTest
  class Refused < StandardError; end

  def self.guard!(cohort_id, environment: Rails.env)
    return unless environment.to_s == "production"
    return if ENV["LOAD_TEST_CONFIRM"] == cohort_id

    raise Refused, "set LOAD_TEST_CONFIRM=#{cohort_id} to confirm this against production"
  end
end
