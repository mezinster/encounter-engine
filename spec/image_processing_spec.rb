require "rails_helper"

# libvips is a SYSTEM library, not a gem, so it can be absent in an environment
# where `bundle install` succeeded — the ruby-vips gem installs fine and then
# fails to find libvips.so at load time. Uploads cannot work without it.
#
# This spec RAISES rather than skips. See spec/helpers/countdown_plural_spec.rb
# for the precedent and CLAUDE.md for why: examples that guard themselves with
# skip() report as pending in CI, which reads exactly like passing unless you
# count them.
describe "libvips" do
  it "loads and performs a real image operation" do
    begin
      require "image_processing/vips"
    rescue LoadError => e
      raise "libvips is unavailable in this environment (#{e.message}). " \
            "Install it: apt-get install -y libvips42 libheif1. " \
            "Do NOT convert this example to a skip."
    end

    # A real operation, not a version string: a version constant can be
    # present while the shared library is too old to actually run.
    image = Vips::Image.black(10, 20)

    expect(image.width).to eq(10)
    expect(image.height).to eq(20)
  end
end
