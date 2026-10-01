require "rails_helper"

describe "shared/_live_status", type: :view do
  it "renders a hidden status line carrying the untranslated %{seconds} slot and both labels" do
    render :partial => "shared/live_status"
    node = Nokogiri::HTML(rendered).at_css("[data-live-status]")

    expect(node["hidden"]).not_to be_nil
    expect(node["data-template"]).to eq("Обновлено %{seconds} с назад")
    expect(node["data-pause-label"]).to eq("Пауза обновления")
    expect(node["data-resume-label"]).to eq("Возобновить обновление")
    expect(node.at_css("button[type=button][data-live-toggle]")).to be_present
    expect(rendered).to match(%r{src="/javascripts/live_region\.js\?v=[0-9a-f]{12}"})
  end
end
