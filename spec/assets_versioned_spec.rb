require "rails_helper"

# Every stylesheet and script under public/ is linked through
# ApplicationHelper#versioned_asset, so its URL changes when the file does
# (see that method for the 2026-10-01 stale-CSS incident). A literal
# href="/stylesheets/..." or src="/javascripts/..." in a template bypasses it
# and brings the stale-cache bug back for that one file -- silently, since
# both suites only ever see a fresh server.
describe "public stylesheets and scripts are versioned" do
  it "links none of them by a fixed URL in any template" do
    offenders = Dir[Rails.root.join("app/views/**/*.erb")].flat_map do |file|
      File.readlines(file).each_with_index.filter_map do |line, index|
        "#{file.delete_prefix("#{Rails.root}/")}:#{index + 1}" if line =~ %r{(href|src)="/(stylesheets|javascripts)/}
      end
    end

    expect(offenders).to eq([])
  end

  it "versions the application layout's stylesheets and scripts", type: :request do
    get root_path

    urls = Nokogiri::HTML(response.body).css("link[rel=stylesheet], script[src]").map { |el| el["href"] || el["src"] }
    local = urls.select { |url| url.start_with?("/stylesheets/", "/javascripts/") }
    expect(local).not_to be_empty
    expect(local.reject { |url| url.match?(/\?v=[0-9a-f]{12}\z/) }).to eq([])
  end
end
