require "spec_helper"
require "skein/runtime_helpers"
require "skein/config"
require "skein/embedder"

RSpec.describe Skein::RuntimeHelpers do
  class DummyRuntime
    include Skein::RuntimeHelpers

    attr_accessor :memory, :timers, :lessons, :events, :db, :config

    def initialize(config:)
      @config = config
      @memory = :memory
      @timers = :timers
      @lessons = :lessons
      @events = :events
      @db = :db
      @logs = []
    end

    def logs
      @logs
    end

    private

    def log(msg)
      @logs << msg
    end
  end

  it "builds skill context from runtime instance state" do
    runtime = DummyRuntime.new(config: Skein::Config.new)

    ctx = runtime.send(:skill_context)

    expect(ctx[:memory]).to eq(:memory)
    expect(ctx[:timers]).to eq(:timers)
    expect(ctx[:lessons]).to eq(:lessons)
    expect(ctx[:events]).to eq(:events)
    expect(ctx[:db]).to eq(:db)
    expect(ctx[:config]).to be_a(Skein::Config)
    expect(ctx[:logger]).to respond_to(:call)
  end

  it "returns nil embedder when embeddings are disabled" do
    config = Skein::Config.new(embedding_enabled: false)
    runtime = DummyRuntime.new(config: config)

    result = runtime.send(:build_embedder)

    expect(result).to be_nil
  end

  it "builds embedder when embeddings are enabled" do
    config = Skein::Config.new(embedding_enabled: true, embedding_model: "model-x")
    runtime = DummyRuntime.new(config: config)
    fake_embedder = double("embedder")

    expect(Skein::Embedder).to receive(:new).with(model_name: "model-x").and_return(fake_embedder)

    result = runtime.send(:build_embedder)

    expect(result).to eq(fake_embedder)
  end

  it "logs and returns nil when embedder load fails" do
    config = Skein::Config.new(embedding_enabled: true, embedding_model: "model-x")
    runtime = DummyRuntime.new(config: config)

    allow(Skein::Embedder).to receive(:new).and_raise(LoadError, "missing dependency")

    result = runtime.send(:build_embedder)

    expect(result).to be_nil
    expect(runtime.logs.last).to match(/Embeddings disabled: missing dependency/)
  end
end
