#!/usr/bin/env ruby
# frozen_string_literal: true

# Pure decision function for the VM scaling proposer (Track 1).
#
# Reads the JSON document ops/vmscale/gather.sh produces on stdin and writes a
# verdict on stdout. It makes no network calls, shells out to nothing and reads
# no clock -- `now_utc` arrives in the input. That purity is the point: it is
# testable from fixtures alone, and when the executor is replaced in Track 3
# this file does not change.
#
# See docs/superpowers/specs/2026-08-20-vm-scaling-track-1-design.md.

require "json"
require "time"

module VMScale
  module Policy
    CREDIT_FLOOR_FRACTION = 0.30
    MEMORY_FLOOR_BYTES    = 200 * 1024 * 1024
    CPU_BUSY_PERCENT      = 80.0
    CPU_BUSY_POINTS       = 12
    WINDOW_POINTS         = 36
    QUIET_DAYS_REQUIRED   = 14
    COOLDOWN_HOURS        = 48
    MB                    = 1024 * 1024
    REQUIRED_SERIES       = %w[cpu_percent available_memory_bytes cpu_credits_remaining].freeze

    module_function

    def decide(input)
      current = input.fetch("current_size")
      found   = evidence(input)
      caveats = input.fetch("activity_log_readable", true) ? [] :
                  ["activity log unreadable: the cooldown is not in force"]

      # Checked first, and before the data check, so that a resize minutes old
      # is never masked by an unrelated metrics gap.
      if (remaining = cooldown_remaining_hours(input))
        return verdict("hold", current, nil, found, caveats +
          [format("cooldown: %.1fh of %dh remaining since the last resize",
                  remaining, COOLDOWN_HOURS)])
      end

      if (gap = metrics_gap(input))
        return verdict("hold", current, nil, found, caveats + [gap])
      end

      breached = breaches(input)
      return scale_up(input, current, found, caveats + breached) if breached.any?

      scale_down(input, current, found, caveats)
    end

    def cooldown_remaining_hours(input)
      last = input["last_resize_utc"]
      return nil if last.nil? || last.to_s.empty?

      # Clamped at zero rather than bailing out when `last` is in the future.
      # A future-dated resize means the runner's clock and the Activity Log's
      # disagree, and the likeliest reason by far is that a resize has only just
      # happened -- so the cooldown belongs at its fullest, not absent. Bailing
      # out failed OPEN in precisely the case that warrants most caution. The
      # suppression stays bounded either way: it lapses 48 hours after now_utc
      # however absurd the timestamp is, and every verdict names it.
      elapsed = [(Time.parse(input.fetch("now_utc")) - Time.parse(last)) / 3600.0, 0.0].max
      return nil if elapsed >= COOLDOWN_HOURS

      COOLDOWN_HOURS - elapsed
    end

    def metrics_gap(input)
      metrics = input.fetch("metrics")

      REQUIRED_SERIES.each do |name|
        size = (metrics[name] || []).size
        if size < WINDOW_POINTS
          return "insufficient data: #{name} returned #{size} of #{WINDOW_POINTS} expected points"
        end
      end

      return "insufficient data: credits_max_7d is missing or zero" unless
        metrics["credits_max_7d"].to_f.positive?

      nil
    end

    def scale_up(input, current, found, breached)
      target = step(input.fetch("ladder"), current, +1)
      if target.nil?
        return verdict("hold", current, nil, found,
                       breached + ["#{current} is the top of the ladder"])
      end

      unless input.fetch("resize_options").include?(target)
        # This list is a property of the physical cluster the VM sits on. A
        # target absent from it would need a deallocate/start cycle rather than
        # a reboot -- a materially different operation, never by surprise.
        return verdict("hold", current, nil, found,
                       breached + ["#{target} is not offered by the cluster this VM sits on"])
      end

      cost    = monthly_total(input, target)
      ceiling = input.fetch("budget_ceiling_usd").to_f
      if cost > ceiling
        # A distinct verdict on purpose. Folding this into "hold" would hide
        # the most important signal the engine can produce; folding it into
        # "scale_up" would propose an action that takes the subscription --
        # and therefore the platform -- offline.
        return verdict("at_budget_ceiling", current, nil, found,
                       breached + [format("%s would cost $%.2f/mo, over the $%.2f ceiling",
                                          target, cost, ceiling)])
      end

      verdict("scale_up", current, target, found, breached)
    end

    def monthly_total(input, size)
      rung = input.fetch("ladder").find { |r| r.fetch("size") == size }
      raise KeyError, "#{size} is not on the ladder" if rung.nil?

      rung.fetch("usd").to_f + input.fetch("baseline_usd").to_f
    end

    def breaches(input)
      metrics = input.fetch("metrics")
      found   = []

      ceiling = metrics.fetch("credits_max_7d").to_f
      lowest  = minimum(metrics["cpu_credits_remaining"])
      floor   = ceiling * CREDIT_FLOOR_FRACTION
      if lowest && ceiling.positive? && lowest < floor
        found << format("cpu credits: min %.1f below %.1f (%d%% of the 7-day max %.1f)",
                        lowest, floor, (CREDIT_FLOOR_FRACTION * 100).round, ceiling)
      end

      lowest_memory = minimum(metrics["available_memory_bytes"])
      if lowest_memory && lowest_memory < MEMORY_FLOOR_BYTES
        found << format("available memory: min %d MB below the %d MB floor",
                        (lowest_memory / MB).round, MEMORY_FLOOR_BYTES / MB)
      end

      window = metrics["cpu_percent"] || []
      busy   = busy_points(window)
      if busy >= CPU_BUSY_POINTS
        found << format("sustained cpu: %d of %d points above %d%%",
                        busy, window.size, CPU_BUSY_PERCENT.round)
      end

      found
    end

    def scale_down(input, current, found, caveats)
      quiet  = found.fetch("quiet_days")
      target = step(input.fetch("ladder"), current, -1)

      if target.nil?
        return verdict("hold", current, nil, found,
                       caveats + ["no threshold breached; #{current} is the floor"])
      end

      if quiet < QUIET_DAYS_REQUIRED
        return verdict("hold", current, nil, found,
                       caveats + ["no threshold breached; #{quiet} of #{QUIET_DAYS_REQUIRED} quiet days"])
      end

      unless input.fetch("resize_options").include?(target)
        return verdict("hold", current, nil, found,
                       caveats + ["#{quiet} quiet days, but #{target} is not offered by the cluster this VM sits on"])
      end

      verdict("scale_down", current, target, found, caveats + ["#{quiet} consecutive quiet days"])
    end

    # A day is quiet when no hour averaged above the CPU line, the lowest
    # available memory stayed above the floor, and the lowest credit balance
    # stayed above 30% of the seven-day peak.
    #
    # Hours, not daily maxima. This VM peaks at 90-99% on most days from
    # deploys and translation runs while spending three credits a week; a daily
    # maximum would score every day busy and scale-down could never fire. An
    # hour whose AVERAGE exceeds 80% can only be sustained load.
    def quiet_days(input)
      metrics = input.fetch("metrics")
      hourly  = metrics["hourly_14d"]
      return 0 if hourly.nil?

      ceiling = metrics.fetch("credits_max_7d").to_f
      floor   = ceiling * CREDIT_FLOOR_FRACTION

      busy    = by_day(hourly["cpu_percent"]) { |hours| busy_points(hours).positive? }
      memory  = by_day(hourly["available_memory_bytes"]) { |hours| minimum(hours) }
      credits = by_day(hourly["cpu_credits_remaining"]) { |hours| minimum(hours) }

      streak = 0
      (busy.keys | memory.keys | credits.keys).sort.reverse_each do |day|
        break if busy[day]
        break if memory[day] && memory[day] < MEMORY_FLOOR_BYTES
        break if credits[day] && ceiling.positive? && credits[day] < floor

        streak += 1
      end
      streak
    end

    def by_day(points)
      (points || []).group_by { |point| point.fetch("t")[0, 10] }
                    .transform_values { |hours| yield(hours) }
    end

    def step(ladder, current, direction)
      here = ladder.index { |rung| rung.fetch("size") == current }
      return nil if here.nil?

      there = here + direction
      return nil if there.negative? || there >= ladder.size

      ladder[there].fetch("size")
    end

    def evidence(input)
      metrics = input.fetch("metrics")
      cpu     = metrics["cpu_percent"] || []
      {
        "window_points"   => cpu.size,
        "cpu_busy_points" => busy_points(cpu),
        "cpu_max_percent" => (cpu.filter_map { |p| p["avg"]&.to_f }.max || 0).round(1),
        "memory_min_mb"   => ((minimum(metrics["available_memory_bytes"]) || 0) / MB).round,
        "credits_min"     => (minimum(metrics["cpu_credits_remaining"]) || 0).round(1),
        "credits_max_7d"  => metrics["credits_max_7d"],
        "quiet_days"      => quiet_days(input)
      }
    end

    def minimum(points)
      (points || []).filter_map { |p| p["min"]&.to_f }.min
    end

    def busy_points(points)
      (points || []).count { |p| p["avg"].to_f > CPU_BUSY_PERCENT }
    end

    def verdict(name, current, target, evidence, reasons)
      {
        "verdict"  => name,
        "current"  => current,
        "target"   => target,
        "reasons"  => reasons,
        "evidence" => evidence
      }
    end
  end
end
