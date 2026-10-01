require "rails_helper"

describe "the translation review table", type: :request do
  let(:superadmin) { u = create_user; u.update!(:is_superadmin => true); u }
  let(:game)  { create_game(:author => create_user, :is_draft => true, :primary_locale => "ru",
                            :available_locale_list => %w[ru en]) }
  let(:level) { create_level(:game => game, :name => "Первый", :text => "Найдите табличку") }
  let(:run)   { TranslationRun.create!(:game => game, :actor => superadmin, :model => "claude-opus-5",
                                       :state => TranslationRun::SUCCEEDED) }
  let(:doc)   { Nokogiri::HTML(response.body) }

  before do
    allow(Translation::Client).to receive(:configured?).and_return(true)
    TranslationProposal.create!(:translation_run => run, :translatable => level, :field => "text",
                                :locale => "en", :source_text => "Найдите табличку",
                                :proposed_text => "Найдите табличку", :flags => "identical",
                                :state => "pending")
    TranslationProposal.create!(:translation_run => run, :translatable => level, :field => "name",
                                :locale => "en", :source_text => "Первый",
                                :proposed_text => "First", :state => "pending")
    put login_path, :params => { :email => superadmin.email, :password => "1234" }
    get game_translation_run_proposals_path(game, run)
  end

  it "has a header and stacks into cards on phones" do
    expect(doc.at_css("table.proposals.table--cards thead")).to be_present
    expect(doc.css("table.proposals thead th").map(&:text).map(&:strip))
      .to eq(%w[Язык Поле Оригинал Перевод Статус])
  end

  it "labels every cell for the stacked layout" do
    cells = doc.css("table.proposals tbody td")
    expect(cells).not_to be_empty
    expect(cells.reject { |td| td["data-label"].present? }).to be_empty
  end

  it "marks a flagged proposal's row and draws its flags as danger tags" do
    flagged = doc.css("table.proposals tbody tr.flagged")
    expect(flagged.size).to eq(1)
    expect(flagged.first.css("ul.flags li.tag.tag--danger").size).to eq(1)
    expect(doc.css("table.proposals tbody tr:not(.flagged)").size).to eq(1)
  end
end
