# -*- encoding : utf-8 -*-
require "rails_helper"

# The storage panel renders "Free disk space (MB)" directly above "Free disk
# space floor (MB)". The floor is the threshold GameFileUpload's disk guard
# compares against, and that guard measures the ACTIVE STORAGE SERVICE ROOT --
# spec/models/game_file_upload_spec.rb pins that distinction in an example
# literally named "probes the filesystem uploads land on, not Rails.root".
#
# The dashboard measured Rails.root. Two numbers side by side, labelled as if
# they were comparable, taken from two different filesystems. Latent today
# because both resolve to the same device; live the day /rails/storage becomes
# the separate partition config/storage.yml recommends, at which point this
# panel reads healthy while every upload is being refused.
#
# Asserting the ARGUMENT rather than the rendered number is the whole point: on
# this machine both paths return the same megabyte figure, so an outcome-based
# example could not tell the two apart and a regression to Rails.root would
# stay green.
describe "the admin dashboard's storage panel", :type => :request do
  before(:each) do
    @admin = create_user
    @admin.update!(:is_superadmin => true)
    put login_path, :params => { :email => @admin.email, :password => "1234" }
  end

  it "probes the filesystem uploads land on, not Rails.root" do
    FileUtils.mkdir_p(ActiveStorage::Blob.service.root)

    # Without this the example proves nothing -- if the two paths were the same
    # string, any argument would satisfy the expectation below.
    expect(GameFileUpload.storage_root).not_to eq(Rails.root.to_s)

    expect(DiskSpace).to receive(:available_megabytes)
      .with(GameFileUpload.storage_root).and_return(4242)

    get admin_dashboard_path

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("4242")
  end

  it "shows the free-space floor the upload guard actually compares against" do
    Setting.put("free_space_floor_megabytes", 777)

    get admin_dashboard_path

    expect(response.body).to include("777")
    expect(response.body).to include(I18n.t("admin.dashboard.show.disk_floor"))
  end
end
