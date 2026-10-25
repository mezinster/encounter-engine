# frozen_string_literal: true

require "spec_helper"
require "yaml"

# The db accessory's image is pinned by digest (see the comment above it in
# config/deploy.yml). A tag here -- :latest especially -- is a time bomb rather
# than a bug: nothing breaks on the day it is written, because `kamal deploy`
# never reboots accessories, and the drift surfaces only at the next reboot,
# which is most likely to be a disaster recovery. So this checks the shape of
# the reference, not the particular digest: moving the pin to a newer image is
# a normal change and must not redden anything.
describe "config/deploy.yml db accessory image" do
  let(:image) do
    YAML.load_file(File.expand_path("../../config/deploy.yml", __dir__))
        .dig("accessories", "db", "image")
  end

  it "is a repository plus a sha256 digest, with no tag" do
    expect(image).to match(%r{\Aghcr\.io/mezinster/encounter-engine-postgres@sha256:\h{64}\z})
  end
end
