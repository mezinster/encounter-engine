# spec/support/query_counter.rb
#
# The N+1 in this feature is invisible in development -- three hints and a
# question look fine -- and expensive in a live game with a full field of
# teams. This makes a forgotten `includes` fail the build instead.
module QueryCounter
  def count_queries(&block)
    count = 0
    counter = ->(_name, _start, _finish, _id, payload) do
      count += 1 unless payload[:name].to_s =~ /SCHEMA|TRANSACTION/
    end
    ActiveSupport::Notifications.subscribed(counter, "sql.active_record", &block)
    count
  end
end

RSpec.configure { |config| config.include QueryCounter }
