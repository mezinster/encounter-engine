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

    module_function

    def decide(input)
      current  = input.fetch("current_size")
      found    = evidence(input)
      breached = breaches(input)

      return scale_up(input, current, found, breached) if breached.any?

      verdict("hold", current, nil, found, ["no threshold breached"])
    end

    def scale_up(input, current, found, breached)
      target = step(input.fetch("ladder"), current, +1)
      if target.nil?
        return verdict("hold", current, nil, found,
                       breached + ["#{current} is the top of the ladder"])
      end

      verdict("scale_up", current, target, found, breached)
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

      found
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
        "quiet_days"      => 0
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
