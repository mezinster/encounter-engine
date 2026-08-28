#!/usr/bin/env ruby
# frozen_string_literal: true

# What one target size would cost per month, and whether that clears the
# ceiling. Prints one JSON object; decides nothing.
#
#   LADDER=ops/vmscale/ladder.json BASELINE_USD=7.5 BUDGET_CEILING_USD=45 \
#     ruby ops/vmscale/affordable.rb Standard_B2s
#   => {"size":"Standard_B2s","monthly_usd":42.54,"ceiling_usd":45.0,"within":true}
#
# Exists for the apply job, which performs resizes that policy.rb never
# proposed: a manual dispatch overrides the engine's verdict wholesale, so the
# `at_budget_ceiling` refusal built into `decide` is simply not on that path.
# On 2026-08-28 a hand-picked Standard_B2ms reached `az vm resize` unpriced.
#
# A separate entry point rather than a flag on policy.rb because the two take
# different inputs: `decide` needs the whole gathered load profile and this
# needs a size and the ladder. It is deliberately thin -- the arithmetic and
# the comparison both live in VMScale::Policy.affordability, which the policy
# spec covers, so that exactly one file in this repository prices a rung.
#
# Exits non-zero only when it cannot answer at all: an unknown size raises
# rather than reporting "unaffordable", because a typo is a broken caller and
# must not read as a budget refusal in the workflow's log.

require "json"
require_relative "policy"

size = ARGV[0].to_s
abort("usage: affordable.rb <size>") if size.empty?

input = {
  "ladder"             => JSON.parse(File.read(ENV.fetch("LADDER"))),
  "baseline_usd"       => ENV.fetch("BASELINE_USD"),
  "budget_ceiling_usd" => ENV.fetch("BUDGET_CEILING_USD")
}

puts JSON.generate(VMScale::Policy.affordability(input, size))
