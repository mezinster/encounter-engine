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
                            :cache_read_input_tokens => usage.fetch(:cache_read, 0),
                            :cache_creation_input_tokens => usage.fetch(:cache_write, 0)))
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

  # The WRITE, not only the read. A prefix written and never read is billed at
  # 1.25x and shows up nowhere else: input_tokens reports only the uncached
  # remainder, so a run that wrote 41,000 tokens and read none looks identical
  # to a run that cached nothing at all. Production ran that way four times
  # before anyone could see it.
  it "carries the cache write back, so an unread write cannot hide" do
    allow(messages).to receive(:create)
      .and_return(api_response([], :usage => { :input => 96, :cache_write => 4_041 }))

    result = client.translate(:unit => unit, :locale => "pl")

    expect(result.cache_write_tokens).to eq(4_041)
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

  # A breakpoint nobody reads is not free: the write costs 1.25x where a plain
  # call costs 1x. One target locale means one call per unit, so the write can
  # never be amortised and the marker is a guaranteed 25% surcharge on input.
  describe "with caching switched off" do
    let(:uncached) do
      described_class.new(:api_key => "sk-ant-test", :model => "claude-opus-5", :cache => false)
    end

    before { allow(uncached).to receive(:messages).and_return(messages) }

    it "sends the source block with no cache breakpoint" do
      expect(messages).to receive(:create) do |args|
        expect(args[:system_].last).not_to have_key(:cache_control)
        expect(args[:system_].last[:text]).to include("Ночной город")
        api_response([])
      end

      uncached.translate(:unit => unit, :locale => "pl")
    end

    # One body, two callers. An estimate built from a differently-shaped body
    # stops describing the run, and nothing would fail to say so.
    it "counts the same breakpoint-free body" do
      expect(messages).to receive(:count_tokens) do |args|
        expect(args[:system_].last).not_to have_key(:cache_control)
        double("count", :input_tokens => 1)
      end

      uncached.count_input_tokens(:unit => unit, :locale => "pl")
    end
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

  # The pre-flight. Free and exact -- the design names it first among three
  # cost guards -- and it prices the request that will actually be sent, not a
  # second approximation of it.
  describe "#count_input_tokens" do
    it "returns the measured input-token count" do
      allow(messages).to receive(:count_tokens)
        .and_return(double("count", :input_tokens => 1_234))

      expect(client.count_input_tokens(:unit => unit, :locale => "pl")).to eq(1_234)
    end

    # If the estimate were built from a different body it would price a run
    # nobody is going to make, and nothing would fail to say so.
    it "counts exactly the body #translate would send, minus max_tokens" do
      expect(messages).to receive(:count_tokens) do |args|
        expect(args[:model]).to eq("claude-opus-5")
        expect(args[:system_].last[:text]).to include("Ночной город")
        expect(args[:system_].last[:cache_control]).to eq({ :type => "ephemeral" })
        expect(args[:messages].first[:content]).to include("Polski")
        expect(args[:output_config][:effort]).to eq("low")
        # count_tokens takes no max_tokens; sending one is a 400.
        expect(args).not_to have_key(:max_tokens)
        double("count", :input_tokens => 1)
      end

      client.count_input_tokens(:unit => unit, :locale => "pl")
    end

    it "raises the seam's own error rather than leaking an SDK exception" do
      allow(messages).to receive(:count_tokens).and_raise(RuntimeError, "boom")

      expect { client.count_input_tokens(:unit => unit, :locale => "pl") }
        .to raise_error(Translation::Client::Error, /boom/)
    end
  end

  it "knows whether an API key is configured at all" do
    allow(ENV).to receive(:[]).with("ANTHROPIC_API_KEY").and_return(nil)
    expect(described_class.configured?).to be false

    allow(ENV).to receive(:[]).with("ANTHROPIC_API_KEY").and_return("sk-ant-x")
    expect(described_class.configured?).to be true
  end
end
