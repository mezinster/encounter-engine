# -*- encoding : utf-8 -*-
#
# RSpec 3 replacements for the two Merb matchers this suite actually uses.
#
# Merb ships them in merb-core/test/matchers/request_matchers.rb, built on
# Spec::Matchers.create. That file is loaded by merb-core/test.rb only after a
# successful `require 'spec'`, which raises LoadError under RSpec 3 — Merb
# rescues it and silently continues, so the matchers simply never exist.
#
# Rather than rewrite Merb's RSpec-1 bridge in the vendored submodule, the two
# matchers are reimplemented here against the public RSpec 3 DSL.

RSpec::Matchers.define :be_successful do
  match do |rack|
    @status = rack.respond_to?(:status) ? rack.status : rack
    (200..207).include?(@status)
  end

  failure_message do |rack|
    "Expected #{rack.inspect} to be successful, but it returned status #{@status}"
  end

  failure_message_when_negated do |rack|
    "Expected #{rack.inspect} not to be successful, but it returned status #{@status}"
  end
end

RSpec::Matchers.alias_matcher :respond_successfully, :be_successful

RSpec::Matchers.define :redirect_to do |expected_location|
  match do |rack|
    @status = rack.respond_to?(:status) ? rack.status : nil
    @location = rack.headers["Location"].to_s.split("?").first

    (300..399).include?(@status) && @location == expected_location
  end

  failure_message do |rack|
    if !(300..399).include?(@status)
      "Expected #{rack.inspect} to be a redirect, but it returned status #{@status}"
    else
      "Expected #{rack.inspect} to redirect to <#{expected_location}>, " \
      "but it redirected to <#{@location}>"
    end
  end

  failure_message_when_negated do |rack|
    "Expected #{rack.inspect} not to redirect to <#{expected_location}>, but it did"
  end
end
