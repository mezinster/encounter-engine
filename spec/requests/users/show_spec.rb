# -*- encoding : utf-8 -*-
require File.join(File.dirname(__FILE__), '..', '..', 'spec_helper.rb')

# Was Merb's `given "..." do` / `describe "...", :given => "..."` DSL, defined in
# merb-core/test/test_ext/rspec.rb on top of RSpec 1's ExampleGroupFactory.
# RSpec 3 expresses the same thing with a shared context.
RSpec.shared_context "a user exists" do
  before(:each) do
    User.create!(:nickname => "valid", :email => "valid@email.com", :password => "1234",
      :password_confirmation => "1234")
  end
end

describe "resource(@user)" do
  include_context "a user exists"

  describe "GET" do
    before(:each) do
      @response = request(resource(User.first))
    end

    it "responds successfully" do
      @response.should be_successful
    end
  end
end
