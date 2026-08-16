require "rails_helper"

describe Translation::Client do
  let(:game)   { create_game(:name => "Ночной город") }
  let(:fields) { game.missing_translated_fields_in("pl").select { |f| f.record == game } }
  let(:unit)   { Translation::Unit.for_game(game, fields) }
  let(:client) { described_class.new(:api_key => "sk-ant-test", :model => "claude-opus-5") }

  # The SDK is stubbed at exactly one seam. No spec in this feature touches the
  # network.
  let(:messages) { double("messages") }

  before { allow(client).to receive(:messages).and_return(messages) }

  def api_response(translations, usage: {})
    double("message",
           :stop_reason => :end_turn,
           :content => [ double("block", :type => :text,
                                :text => { "translations" => translations }.to_json) ],
           :usage => double("usage",
                            :input_tokens  => usage.fetch(:input, 100),
                            :output_tokens => usage.fetch(:output, 50),
                            :cache_read_input_tokens => usage.fetch(:cache_read, 0)))
  end

  it "returns translated text keyed by field key" do
    key = Translation::Unit.field_key(game, "name")
    allow(messages).to receive(:create)
      .and_return(api_response([ { "key" => key, "text" => "Nocne miasto" } ]))

    result = client.translate(:unit => unit, :locale => "pl")

    expect(result.texts).to eq(key => "Nocne miasto")
  end

  it "carries usage back so the run can prove its caching is hitting" do
    allow(messages).to receive(:create)
      .and_return(api_response([], :usage => { :input => 900, :output => 300, :cache_read => 800 }))

    result = client.translate(:unit => unit, :locale => "pl")

    expect(result.input_tokens).to eq(900)
    expect(result.output_tokens).to eq(300)
    expect(result.cache_read_tokens).to eq(800)
  end

  # The cache breakpoint sits on the SOURCE block, so the only thing after it
  # is "translate into X". Move it and every locale after the first becomes a
  # cache miss.
  it "puts the cache breakpoint on the source block, with the locale after it" do
    expect(messages).to receive(:create) do |args|
      expect(args[:system_].last[:cache_control]).to eq({ :type => "ephemeral" })
      expect(args[:system_].last[:text]).to include("Ночной город")
      expect(args[:messages].first[:content]).to include("Polski")
      expect(args[:output_config][:effort]).to eq("low")
      api_response([])
    end

    client.translate(:unit => unit, :locale => "pl")
  end

  # stop_reason is read BEFORE content. Code that indexes content[0]
  # unconditionally breaks on a refusal, and production is a bad place to
  # find that out.
  it "raises rather than reading content when the model refuses" do
    allow(messages).to receive(:create)
      .and_return(double("message", :stop_reason => :refusal, :stop_details => nil,
                                    :content => [], :usage => nil))

    expect { client.translate(:unit => unit, :locale => "pl") }
      .to raise_error(Translation::Client::Error, /refus/i)
  end

  it "knows whether an API key is configured at all" do
    allow(ENV).to receive(:[]).with("ANTHROPIC_API_KEY").and_return(nil)
    expect(described_class.configured?).to be false

    allow(ENV).to receive(:[]).with("ANTHROPIC_API_KEY").and_return("sk-ant-x")
    expect(described_class.configured?).to be true
  end
end
