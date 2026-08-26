#!/usr/bin/env ruby
# frozen_string_literal: true

# Turns "which vendor is live" plus the endpoint map into the facts both
# workflows need, so they cannot disagree about what production is doing.
#
# BOTH .github/workflows/deploy.yml and .github/workflows/smtp-probe.yml call
# this. That is the point: the probe following the deploy automatically -- in
# host AND credential -- is what removes the class of bug where a cutover leaves
# the monitor testing the vendor you just left.
#
# `resolve` is pure: no network, no clock, no ENV. Same split as
# ops/vmscale/policy.rb -- the caller gathers, the Ruby decides.
#
# No Rails. This runs on a bare GitHub runner; yaml and json only.

require "yaml"

module SMTPRoles
  ENDPOINTS_PATH = "ops/smtp/endpoints.yml"

  module_function

  # role -> the vendor name that is currently live, e.g. "gmail".
  # endpoints -> the parsed contents of ENDPOINTS_PATH.
  def resolve(role:, endpoints:)
    vendor = role.to_s
    raise ArgumentError, "MAIL_ROLE is empty -- nothing says which vendor is live" if vendor.empty?

    unless endpoints.key?(vendor)
      raise ArgumentError,
            "MAIL_ROLE is #{vendor.inspect}, which is not in #{ENDPOINTS_PATH} " \
            "(known: #{endpoints.keys.join(', ')})"
    end

    standby = (endpoints.keys - [vendor]).first
    if standby.nil?
      raise ArgumentError,
            "#{ENDPOINTS_PATH} names only #{vendor.inspect}, so there is no standby to watch"
    end

    { "live" => facts(vendor, endpoints), "standby" => facts(standby, endpoints) }
  end

  def facts(vendor, endpoints)
    entry = endpoints.fetch(vendor)
    host  = entry["host"].to_s
    raise ArgumentError, "#{ENDPOINTS_PATH} entry #{vendor.inspect} has no host" if host.empty?

    { "vendor" => vendor, "host" => host, "port" => (entry["port"] || 587).to_i }
  end
end

if $PROGRAM_NAME == __FILE__
  resolved = SMTPRoles.resolve(
    :role      => ENV["MAIL_ROLE"],
    :endpoints => YAML.safe_load_file(SMTPRoles::ENDPOINTS_PATH)
  )

  File.open(ENV.fetch("GITHUB_OUTPUT"), "a") do |f|
    %w[live standby].each do |slot|
      resolved.fetch(slot).each { |key, value| f.puts "#{slot}_#{key}=#{value}" }
    end
  end

  # stderr, so it lands in the run log without polluting anything parsing stdout.
  warn "live: #{resolved['live']['vendor']} (#{resolved['live']['host']}:#{resolved['live']['port']}) " \
       "standby: #{resolved['standby']['vendor']}"
end
