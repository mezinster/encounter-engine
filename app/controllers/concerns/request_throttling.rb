# -*- encoding : utf-8 -*-
#
# A fixed-window per-IP counter for the two unauthenticated endpoints that send
# mail. Both hand an attacker-chosen address to the SMTP account configured in
# config/environments/production.rb (Gmail by default, which suspends senders
# that trip its spam heuristics) and both deliver synchronously, so each request
# also holds a Puma thread for the length of an SMTP round trip.
#
# NOT Rails 8's built-in `rate_limit`. That macro captures `to:` and `within:`
# when the controller class is loaded, so its numbers are frozen until the next
# deploy -- and the requirement here is that a superadmin can change them from
# the console during an incident (see Admin::SettingsController).
#
# Fixed window, not sliding: a client can burst up to 2x the limit across a
# window boundary. That is a known and accepted property. The alternative costs
# a sorted set per client, and this is a spam brake, not a security boundary.
module RequestThrottling
  extend ActiveSupport::Concern

  private

  # Returns true when the request is under the limit and may proceed.
  def throttle!(name)
    limit = Setting.integer("#{name}_max")
    # 0 disables. Checked before anything is written, so a disabled limit costs
    # no cache traffic at all.
    return true if limit.zero?

    window = Setting.integer("#{name}_window_seconds")
    bucket = Time.now.to_i / window
    key    = "throttle:#{name}:#{request.remote_ip}:#{bucket}"

    # MemoryStore#increment initialises a missing key, but the fallback is kept
    # so this concern does not silently stop counting if the store is ever
    # swapped for one that returns nil instead.
    count = Rails.cache.increment(key, 1, :expires_in => window.seconds + 1.minute)
    if count.nil?
      Rails.cache.write(key, 1, :expires_in => window.seconds + 1.minute)
      count = 1
    end

    return true if count <= limit

    # Both values, deliberately: this line is the evidence for the
    # remote_ip-behind-kamal-proxy check recorded in
    # config/environments/production.rb. If remote_ip is a private address
    # while xff carries the real one, the limiter is keying on the proxy and is
    # treating the whole internet as a single client.
    Rails.logger.warn(
      "[throttle] #{name} over limit: remote_ip=#{request.remote_ip} " \
      "xff=#{request.headers['X-Forwarded-For'].inspect} " \
      "count=#{count} limit=#{limit} window=#{window}s"
    )
    false
  end
end
