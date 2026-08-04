# -*- encoding : utf-8 -*-
require "rails_helper"

RSpec.describe "database schema" do
  EXPECTED_TABLES = %w[
    answers game_entries game_passings games hints
    invitations levels logs questions teams users
  ].freeze

  it "creates every table the application needs" do
    expect(ActiveRecord::Base.connection.tables).to include(*EXPECTED_TABLES)
  end

  it "keeps answered_questions on game_passings as text" do
    column = ActiveRecord::Base.connection.columns(:game_passings)
                               .find { |c| c.name == "answered_questions" }
    expect(column.type).to eq(:text)
  end
end
