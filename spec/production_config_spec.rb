require "rails_helper"

RSpec.describe "production environment configuration" do
  # Loading a second environment inside a running app is not possible, so read
  # the file and assert on its content. Crude, but it pins the four settings
  # whose absence breaks production in ways no other test can see.
  let(:source) { File.read(Rails.root.join("config/environments/production.rb")) }

  it "assumes SSL, or force_ssl loops forever behind kamal-proxy" do
    expect(source).to match(/config\.assume_ssl\s*=\s*true/)
  end

  it "logs to STDOUT, or logs are trapped inside the container" do
    expect(source).to match(/config\.logger\s*=.*STDOUT/)
  end

  it "sets a mailer host, or invitation links render broken" do
    expect(source).to match(/default_url_options.*APP_HOST/m)
  end

  it "configures SMTP, or mail silently goes to localhost:25" do
    expect(source).to match(/smtp_settings/)
    expect(source).to match(/SMTP_USERNAME/)
  end
end
