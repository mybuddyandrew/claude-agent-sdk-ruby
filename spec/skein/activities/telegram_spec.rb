require "spec_helper"
require "skein/activities/telegram"

RSpec.describe Skein::Activities::Telegram do
  let(:token) { "test-token" }
  let(:telegram) do
    described_class.new(
      token: token,
      open_timeout: 11,
      post_read_timeout: 31,
      poll_read_timeout_buffer: 7
    )
  end

  it "poll uses timeout plus configured buffer" do
    response = Struct.new(:body).new('{"ok":true,"result":[]}')

    expect(telegram).to receive(:get) do |_uri, read_timeout:|
      expect(read_timeout).to eq(27)
      response
    end

    updates = telegram.poll(timeout: 20)
    expect(updates).to eq([])
  end

  it "poll updates offset and returns updates" do
    response = Struct.new(:body).new(
      '{"ok":true,"result":[{"update_id":1,"message":{"text":"hi"}},{"update_id":3,"message":{"text":"yo"}}]}'
    )
    allow(telegram).to receive(:get).and_return(response)

    updates = telegram.poll(timeout: 5)

    expect(updates.size).to eq(2)

    expect(telegram).to receive(:get) do |uri, read_timeout:|
      expect(uri.query).to include("offset=4")
      expect(read_timeout).to eq(12)
      Struct.new(:body).new('{"ok":true,"result":[]}')
    end
    telegram.poll(timeout: 5)
  end

  it "poll returns empty array on invalid JSON" do
    allow(telegram).to receive(:get).and_return(Struct.new(:body).new("not-json"))
    allow(telegram).to receive(:warn)

    result = telegram.poll(timeout: 5)

    expect(result).to eq([])
    expect(telegram).to have_received(:warn).with(/poll error/)
  end

  it "poll returns empty array on non-ok responses" do
    allow(telegram).to receive(:get).and_return(Struct.new(:body).new('{"ok":false}'))

    result = telegram.poll(timeout: 5)

    expect(result).to eq([])
  end

  it "send_message returns parsed result on success" do
    response = Struct.new(:body).new('{"ok":true,"result":{"message_id":123}}')
    allow(telegram).to receive(:post).and_return(response)

    result = telegram.send_message(chat_id: "42", text: "hello")

    expect(result).to eq({ "message_id" => 123 })
  end

  it "send_message returns nil on failed API response" do
    response = Struct.new(:body).new('{"ok":false,"description":"bad request"}')
    allow(telegram).to receive(:post).and_return(response)
    allow(telegram).to receive(:warn)

    result = telegram.send_message(chat_id: "42", text: "hello")

    expect(result).to be_nil
  end

  it "send_message re-raises unexpected errors" do
    allow(telegram).to receive(:post).and_raise(StandardError, "boom")
    allow(telegram).to receive(:warn)

    expect {
      telegram.send_message(chat_id: "42", text: "hello")
    }.to raise_error(StandardError, /boom/)
    expect(telegram).to have_received(:warn).with(/send error/)
  end

  it "get uses configured open timeout" do
    fake_http = instance_double(Net::HTTP)
    allow(fake_http).to receive(:use_ssl=)
    allow(fake_http).to receive(:open_timeout=)
    allow(fake_http).to receive(:read_timeout=)
    allow(fake_http).to receive(:request).and_return(Struct.new(:body).new('{}'))
    allow(Net::HTTP).to receive(:new).and_return(fake_http)

    uri = URI("https://api.telegram.org/bot#{token}/getUpdates")
    telegram.send(:get, uri, read_timeout: 44)

    expect(fake_http).to have_received(:open_timeout=).with(11)
    expect(fake_http).to have_received(:read_timeout=).with(44)
  end

  it "post uses configured open timeout and post read timeout" do
    fake_http = instance_double(Net::HTTP)
    allow(fake_http).to receive(:use_ssl=)
    allow(fake_http).to receive(:open_timeout=)
    allow(fake_http).to receive(:read_timeout=)
    allow(fake_http).to receive(:request).and_return(Struct.new(:body).new('{}'))
    allow(Net::HTTP).to receive(:new).and_return(fake_http)

    uri = URI("https://api.telegram.org/bot#{token}/sendMessage")
    telegram.send(:post, uri, { chat_id: "42", text: "hello" })

    expect(fake_http).to have_received(:open_timeout=).with(11)
    expect(fake_http).to have_received(:read_timeout=).with(31)
  end

  it "get returns nil on connection failures" do
    allow(Net::HTTP).to receive(:new).and_raise(SocketError, "dns")
    allow(telegram).to receive(:warn)

    uri = URI("https://api.telegram.org/bot#{token}/getUpdates")
    result = telegram.send(:get, uri, read_timeout: 44)

    expect(result).to be_nil
    expect(telegram).to have_received(:warn).with(/connection error/)
  end

  it "post returns nil on connection failures" do
    allow(Net::HTTP).to receive(:new).and_raise(SocketError, "dns")
    allow(telegram).to receive(:warn)

    uri = URI("https://api.telegram.org/bot#{token}/sendMessage")
    result = telegram.send(:post, uri, { chat_id: "42", text: "hello" })

    expect(result).to be_nil
    expect(telegram).to have_received(:warn).with(/connection error/)
  end
end
