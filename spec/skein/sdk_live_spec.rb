# frozen_string_literal: true

require 'spec_helper'
require 'skein/sdk_client'
require 'skein/memory'
require 'skein/timer'
require 'skein/event_store'
require 'skein/tool_executor'
require 'skein/config'
require 'skein/tools/remember'
require 'skein/tools/recall'
require 'skein/tools/send_telegram'
require 'skein/tools/create_reminder'
require 'skein/tools/write_note'

# Live integration tests using the real Claude Agent SDK.
# These use the Max subscription and take 5-15 seconds per test.
# Only run explicitly: SKEIN_LIVE_TEST=1 bundle exec rspec spec/skein/sdk_live_spec.rb
RSpec.describe Skein::SdkClient, :live do
  before(:all) do
    skip 'Set SKEIN_LIVE_TEST=1 to run live tests' unless ENV['SKEIN_LIVE_TEST']
  end

  let(:db) { Skein::DB.new(':memory:') }
  let(:events) { Skein::EventStore.new(db) }
  let(:memory) { Skein::Memory.new(db: db, event_store: events) }
  let(:timers) { Skein::Timer.new(db: db, event_store: events) }
  let(:executor) { Skein::ToolExecutor.new(memory: memory, timers: timers) }
  let(:config) { Skein::Config.new }

  let(:channel) do
    mock = Object.new
    mock.define_singleton_method(:send_reply) { |_chat_id, _text| }
    mock.define_singleton_method(:request_approval) { |_chat_id, _tool_name, _tool_input| 'allow' }
    mock
  end

  def build_client
    Skein::SdkClient.new(
      config: config,
      tool_executor: executor,
      channel: channel,
      logger: ->(msg) { puts "  [LIVE] #{msg}" }
    )
  end

  # Basic query -- no tools, just a simple response
  it 'handles a simple query' do
    client = build_client
    client.start

    result = client.send_task(
      'What is 2 + 2? Reply with just the number.',
      chat_id: 'test',
      timeout: 60
    )

    expect(result['type']).to eq('result')
    expect(result['text']).to match(/4/)
    expect(result['session_id']).not_to be_empty

    puts "\n  [LIVE] Simple query: #{result['text'][0..100]}"
    puts "  [LIVE] Session: #{result['session_id']}"
  ensure
    client&.shutdown
  end

  # Tool use -- ask Claude to remember something, verify it's stored in Ruby's DB
  it 'executes remember tool via MCP' do
    client = build_client
    client.start

    result = client.send_task(
      'Please remember that my favorite language is Ruby.',
      chat_id: 'test',
      memories: '',
      lessons: '',
      timeout: 60
    )

    expect(result['type']).to eq('result')
    expect(memory.count).to be >= 1

    memories = memory.search(query: 'Ruby', limit: 5)
    expect(memories.any? { |m| m['content'].include?('Ruby') }).to be_truthy,
      "Expected a memory about Ruby. Got: #{memories.map { |m| m['content'] }}"

    puts "\n  [LIVE] Remember tool: stored #{memory.count} memories"
  ensure
    client&.shutdown
  end

  # Session continuity -- send two messages, second should remember context
  it 'maintains session continuity' do
    client = build_client
    client.start

    r1 = client.send_task(
      'My name is TestUser. Please remember that.',
      chat_id: 'test',
      timeout: 60
    )
    expect(r1['type']).to eq('result')
    session_id = r1['session_id']
    expect(session_id).not_to be_empty

    r2 = client.send_task(
      'What is my name?',
      chat_id: 'test',
      session_id: session_id,
      timeout: 60
    )
    expect(r2['type']).to eq('result')
    expect(r2['text']).to match(/TestUser/i),
      "Expected Claude to remember 'TestUser'. Got: #{r2['text']}"

    puts "\n  [LIVE] Session continuity working"
  ensure
    client&.shutdown
  end

  # Lesson extraction via structured output
  it 'extracts lessons from conversation text' do
    client = build_client
    client.start

    conversation = "user: How do I sort an array in Ruby?\n" \
                   "assistant: Use `array.sort` or `array.sort_by { |x| x.length }` for custom sorting."
    result = client.send_extract(conversation, extract_type: 'lessons', timeout: 60)

    expect(result).to be_a(Hash)
    expect(result).to have_key('lessons')
    expect(result['lessons']).to be_an(Array)

    puts "\n  [LIVE] Extraction: #{result['lessons'].size} lessons"
    result['lessons'].each { |l| puts "  [LIVE]   [#{l['category']}] #{l['content']}" }
  ensure
    client&.shutdown
  end

  # Memory extraction via structured output
  it 'extracts memories from conversation text' do
    client = build_client
    client.start

    conversation = "user: I'm working on a project called Skein. It's a personal assistant built in Ruby 4.0.\n" \
                   "assistant: That sounds great! Ruby 4.0 has some nice improvements."
    result = client.send_extract(conversation, extract_type: 'memories', timeout: 60)

    expect(result).to be_a(Hash)
    expect(result).to have_key('memories')
    expect(result['memories']).to be_an(Array)

    puts "\n  [LIVE] Memory extraction: #{result['memories'].size} memories"
  ensure
    client&.shutdown
  end

  # Decomposition check
  it 'decomposes complex tasks' do
    client = build_client
    client.start

    complex_input = 'Set up a new Rails project with PostgreSQL, add user authentication with Devise, ' \
                    'create a CI/CD pipeline with GitHub Actions, and deploy to Fly.io with SSL'
    result = client.send_decompose(complex_input, timeout: 60)

    expect(result).to be_a(Hash)
    expect([true, false]).to include(result['decompose'])
    expect(result['subtasks']).to be_an(Array)

    if result['decompose']
      expect(result['subtasks'].size).to be >= 2
      puts "\n  [LIVE] Decompose: #{result['subtasks'].size} subtasks"
      result['subtasks'].each { |s| puts "  [LIVE]   #{s['title']}" }
    else
      puts "\n  [LIVE] LLM chose not to decompose (acceptable)"
    end
  ensure
    client&.shutdown
  end
end
