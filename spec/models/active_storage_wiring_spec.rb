require "rails_helper"

# Active Storage arrives by an explicit railtie require, because
# config/application.rb requires railties one at a time rather than using
# rails/all. These examples fail loudly if that require is ever dropped —
# which would otherwise show up as a NameError deep inside an upload.
describe "Active Storage wiring" do
  it "defines the blob model" do
    expect(defined?(ActiveStorage::Blob)).to eq("constant")
  end

  it "has all three tables" do
    %w[active_storage_blobs active_storage_attachments active_storage_variant_records].each do |table|
      expect(ActiveRecord::Base.connection.table_exists?(table)).to be(true), "missing #{table}"
    end
  end

  it "runs jobs inline rather than on a queue that does not exist" do
    # :async would silently drop queued work when the container stops, and
    # this app has no durable queue. See the design's invariant I2.
    expect(ActiveJob::Base.queue_adapter_name).to eq("inline")
  end

  it "stores test uploads somewhere disposable" do
    expect(Rails.application.config.active_storage.service).to eq(:test)
  end

  # Requiring a Rails engine is not an inert act -- an engine can contribute
  # routes, middleware and initializers. Active Storage's own routes include an
  # unauthenticated write path; see config/application.rb.
  it "publishes none of Active Storage's own routes" do
    active_storage_paths = Rails.application.routes.routes.map { |r| r.path.spec.to_s }
                                .select { |path| path.start_with?("/rails/active_storage") }

    expect(active_storage_paths).to be_empty
  end
end
