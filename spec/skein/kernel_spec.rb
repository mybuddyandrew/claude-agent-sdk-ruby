require "spec_helper"
require "skein"
require "tempfile"

RSpec.describe Skein::Kernel do
  def stub_kernel_boot(config:, timers_existing_heartbeat: true)
    db = instance_double(Skein::DB)
    events = instance_double(Skein::EventStore)
    tasks = instance_double(Skein::Task)
    timers = instance_double(Skein::Timer)
    memory = instance_double(Skein::Memory)
    lessons = instance_double(Skein::Lesson)
    lane = instance_double(Skein::Lane)
    telegram = instance_double(Skein::Activities::Telegram)
    tool_executor = instance_double(Skein::ToolExecutor)
    skill_registry = instance_double(Skein::SkillRegistry)
    sdk_client = instance_double(Skein::SdkClient)
    agent = instance_double(Skein::Agent)
    dispatcher = instance_double(Skein::Dispatcher::Sequential)

    allow(Skein::Config).to receive(:new).and_return(config)

    allow(Skein::DB).to receive(:new).and_return(db)
    allow(Skein::EventStore).to receive(:new).with(db).and_return(events)
    allow(Skein::Task).to receive(:new).with(db: db, event_store: events).and_return(tasks)
    allow(Skein::Timer).to receive(:new).with(db: db, event_store: events).and_return(timers)
    allow(Skein::Memory).to receive(:new).with(db: db, event_store: events, embedder: nil).and_return(memory)
    allow(Skein::Lesson).to receive(:new).with(db: db, event_store: events).and_return(lessons)
    allow(Skein::Lane).to receive(:new).with(task: tasks).and_return(lane)
    allow(Skein::Activities::Telegram).to receive(:new).and_return(telegram)
    allow(Skein::ToolExecutor).to receive(:new).and_return(tool_executor)
    allow(Skein::SkillRegistry).to receive(:new).and_return(skill_registry)
    allow(skill_registry).to receive(:load_all!)
    allow(skill_registry).to receive(:register_tools!).with(tool_executor)
    allow(skill_registry).to receive(:setup_schedules!)
    allow(Skein::SdkClient).to receive(:new).and_return(sdk_client)
    allow(Skein::Agent).to receive(:new).and_return(agent)
    allow(Skein::Dispatcher::Sequential).to receive(:new).and_return(dispatcher)

    allow(agent).to receive(:start_sdk)
    allow(agent).to receive(:recover_stale_tasks!)
    allow(agent).to receive(:maintenance!)

    if timers_existing_heartbeat
      allow(timers).to receive(:find_by_name).with("heartbeat").and_return({ "id" => 1 })
    else
      allow(timers).to receive(:find_by_name).with("heartbeat").and_return(nil)
      allow(timers).to receive(:create)
    end

    allow(Signal).to receive(:trap)
    allow_any_instance_of(Skein::Kernel).to receive(:log)

    {
      db: db,
      events: events,
      tasks: tasks,
      timers: timers,
      memory: memory,
      lessons: lessons,
      lane: lane,
      telegram: telegram,
      tool_executor: tool_executor,
      skill_registry: skill_registry,
      sdk_client: sdk_client,
      agent: agent,
      dispatcher: dispatcher,
    }
  end

  it "initializes DB and Telegram with configured timeouts" do
    config = Skein::Config.new(
      telegram_token: "tok",
      db_path: "/tmp/skein-kernel.db",
      db_busy_timeout_ms: 4321,
      telegram_open_timeout: 11,
      telegram_post_read_timeout: 22,
      telegram_poll_read_timeout_buffer: 3,
      embedding_enabled: false
    )

    stub_kernel_boot(config: config)

    expect(Skein::DB).to receive(:new).with("/tmp/skein-kernel.db", busy_timeout_ms: 4321)
    expect(Skein::Activities::Telegram).to receive(:new).with(
      token: "tok",
      open_timeout: 11,
      post_read_timeout: 22,
      poll_read_timeout_buffer: 3
    )

    described_class.new
  end

  it "raises when telegram token is missing" do
    config = Skein::Config.new(telegram_token: nil)
    allow(Skein::Config).to receive(:new).and_return(config)

    expect {
      described_class.new
    }.to raise_error(ArgumentError, /SKEIN_TELEGRAM_TOKEN is required/)
  end

  it "creates heartbeat timer when missing" do
    config = Skein::Config.new(
      telegram_token: "tok",
      db_path: "/tmp/skein-kernel.db",
      heartbeat_interval: 123,
      embedding_enabled: false
    )

    boot = stub_kernel_boot(config: config, timers_existing_heartbeat: false)
    expect(boot[:timers]).to receive(:create).with(
      name: "heartbeat",
      next_fire_at: kind_of(Time),
      interval_seconds: 123
    )

    described_class.new
  end

  it "request_approval truncates tool input and uses configured poll timeout" do
    kernel = described_class.allocate
    config = Skein::Config.new(
      approval_timeout: 60,
      approval_poll_timeout: 7,
      approval_input_preview_length: 10
    )
    telegram = instance_double(Skein::Activities::Telegram)
    kernel.instance_variable_set(:@config, config)
    kernel.instance_variable_set(:@telegram, telegram)
    kernel.instance_variable_set(:@queued_updates, [])

    sent_message = nil
    allow(kernel).to receive(:send_reply) { |_chat_id, text| sent_message = text }
    expect(telegram).to receive(:poll).with(timeout: 7).and_return([
      {
        "message" => {
          "text" => "/approve",
          "chat" => { "id" => "123" },
        },
      },
    ])

    result = kernel.request_approval("123", "Bash", { "command" => "x" * 50 })

    expect(result).to eq("allow")
    summary = sent_message[/Bash\((.*)\)\n\n/m, 1]
    expect(summary).to end_with("...")
    expect(summary.length).to eq(13)
  end

  it "request_approval queues non-approval messages while waiting" do
    kernel = described_class.allocate
    config = Skein::Config.new(
      approval_timeout: 60,
      approval_poll_timeout: 3,
      approval_input_preview_length: 20
    )
    telegram = instance_double(Skein::Activities::Telegram)
    kernel.instance_variable_set(:@config, config)
    kernel.instance_variable_set(:@telegram, telegram)
    kernel.instance_variable_set(:@queued_updates, [])

    allow(kernel).to receive(:send_reply)

    non_approval = {
      "message" => {
        "text" => "hello",
        "chat" => { "id" => "123" },
      },
    }
    denial = {
      "message" => {
        "text" => "/deny",
        "chat" => { "id" => "123" },
      },
    }
    allow(telegram).to receive(:poll).with(timeout: 3).and_return([non_approval], [denial])

    result = kernel.request_approval("123", "Bash", {})

    expect(result).to eq("deny")
    expect(kernel.instance_variable_get(:@queued_updates)).to eq([non_approval])
  end

  it "request_approval queues messages for other chats" do
    kernel = described_class.allocate
    config = Skein::Config.new(
      approval_timeout: 60,
      approval_poll_timeout: 3,
      approval_input_preview_length: 20
    )
    telegram = instance_double(Skein::Activities::Telegram)
    kernel.instance_variable_set(:@config, config)
    kernel.instance_variable_set(:@telegram, telegram)
    kernel.instance_variable_set(:@queued_updates, [])

    allow(kernel).to receive(:send_reply)

    other_chat_msg = {
      "message" => {
        "text" => "from another chat",
        "chat" => { "id" => "999" },
      },
    }
    approval = {
      "message" => {
        "text" => "/approve",
        "chat" => { "id" => "123" },
      },
    }
    allow(telegram).to receive(:poll).with(timeout: 3).and_return([other_chat_msg], [approval])

    result = kernel.request_approval("123", "Bash", {})

    expect(result).to eq("allow")
    expect(kernel.instance_variable_get(:@queued_updates)).to eq([other_chat_msg])
  end

  it "request_approval denies when timeout is exceeded" do
    kernel = described_class.allocate
    config = Skein::Config.new(
      approval_timeout: 0,
      approval_poll_timeout: 3,
      approval_input_preview_length: 20
    )
    telegram = instance_double(Skein::Activities::Telegram)
    kernel.instance_variable_set(:@config, config)
    kernel.instance_variable_set(:@telegram, telegram)
    kernel.instance_variable_set(:@queued_updates, [])

    allow(kernel).to receive(:send_reply)
    now = Time.at(1_000_000)
    allow(Time).to receive(:now).and_return(now, now + 1)
    expect(telegram).not_to receive(:poll)

    result = kernel.request_approval("123", "Bash", {})
    expect(result).to eq("deny")
  end

  describe "heartbeat task creation" do
    it "uses heartbeat checklist file when present" do
      checklist = Tempfile.new("heartbeat")
      checklist.write("- review reminders\n- summarize context\n")
      checklist.flush

      kernel = described_class.allocate
      config = Skein::Config.new(heartbeat_path: checklist.path)
      tasks = instance_double(Skein::Task)
      kernel.instance_variable_set(:@config, config)
      kernel.instance_variable_set(:@tasks, tasks)

      expect(tasks).to receive(:create).with(
        source: "heartbeat",
        lane: Skein::Lane::L0_INTERRUPT,
        input_text: include("review reminders")
      )

      kernel.send(:run_heartbeat, nil)
    ensure
      checklist.close!
    end

    it "uses fallback text when checklist file is missing" do
      kernel = described_class.allocate
      config = Skein::Config.new(heartbeat_path: "/tmp/missing-heartbeat-checklist.md")
      tasks = instance_double(Skein::Task)
      kernel.instance_variable_set(:@config, config)
      kernel.instance_variable_set(:@tasks, tasks)

      expect(tasks).to receive(:create).with(
        source: "heartbeat",
        lane: Skein::Lane::L0_INTERRUPT,
        input_text: include("No heartbeat checklist found.")
      )

      kernel.send(:run_heartbeat, nil)
    end
  end

  describe "custom timer delivery" do
    it "creates and completes a reminder task when delivery succeeds" do
      kernel = described_class.allocate
      tasks = instance_double(Skein::Task)
      telegram = instance_double(Skein::Activities::Telegram)
      kernel.instance_variable_set(:@tasks, tasks)
      kernel.instance_variable_set(:@telegram, telegram)
      allow(kernel).to receive(:log)

      timer = { "payload" => { "chat_id" => "123", "text" => "stretch" } }

      expect(tasks).to receive(:create).with(
        source: "timer",
        chat_id: "123",
        input_text: "stretch",
        lane: Skein::Lane::L1_INTERACTIVE
      ).and_return(42)
      expect(tasks).to receive(:transition!).with(42, "running")
      expect(telegram).to receive(:send_message).with(chat_id: "123", text: "Reminder: stretch")
      expect(tasks).to receive(:transition!).with(42, "completed", result_text: "Reminder delivered")

      kernel.send(:run_custom_timer, timer)
    end

    it "marks timer task failed when delivery raises" do
      kernel = described_class.allocate
      tasks = instance_double(Skein::Task)
      telegram = instance_double(Skein::Activities::Telegram)
      kernel.instance_variable_set(:@tasks, tasks)
      kernel.instance_variable_set(:@telegram, telegram)
      allow(kernel).to receive(:log)

      timer = { "payload" => { "chat_id" => "123", "text" => "stretch" } }

      expect(tasks).to receive(:create).and_return(42)
      expect(tasks).to receive(:transition!).with(42, "running")
      expect(telegram).to receive(:send_message).and_raise(StandardError, "network down")
      expect(tasks).to receive(:transition!).with(42, "failed", error_message: "network down")

      kernel.send(:run_custom_timer, timer)
      expect(kernel).to have_received(:log).with(/Timer delivery error: network down/)
    end
  end

  describe "message splitting" do
    it "send_reply ignores nil chat_id" do
      kernel = described_class.allocate
      telegram = instance_double(Skein::Activities::Telegram)
      kernel.instance_variable_set(:@telegram, telegram)

      expect(telegram).not_to receive(:send_message)
      kernel.send_reply(nil, "hello")
    end

    it "send_reply sends one message when under Telegram max length" do
      kernel = described_class.allocate
      telegram = instance_double(Skein::Activities::Telegram)
      kernel.instance_variable_set(:@telegram, telegram)

      expect(telegram).to receive(:send_message).with(chat_id: "123", text: "hello")
      kernel.send_reply("123", "hello")
    end

    it "send_reply splits long messages into multiple chunks" do
      kernel = described_class.allocate
      telegram = instance_double(Skein::Activities::Telegram)
      kernel.instance_variable_set(:@telegram, telegram)
      long_text = "a" * (Skein::Kernel::TELEGRAM_MAX_LENGTH + 20)

      expect(telegram).to receive(:send_message).twice
      kernel.send_reply("123", long_text)
    end

    it "send_reply swallows Telegram errors" do
      kernel = described_class.allocate
      telegram = instance_double(Skein::Activities::Telegram)
      kernel.instance_variable_set(:@telegram, telegram)
      allow(kernel).to receive(:log)

      allow(telegram).to receive(:send_message).and_raise(StandardError, "boom")

      expect { kernel.send_reply("123", "hello") }.not_to raise_error
      expect(kernel).to have_received(:log).with(/Telegram send error: boom/)
    end

    it "prefers splitting at newline boundaries" do
      kernel = described_class.allocate
      text = "alpha\n" + ("b" * 20)

      chunks = kernel.send(:split_message, text, 10)

      expect(chunks.first).to eq("alpha")
      expect(chunks.join).to eq("alphabbbbbbbbbbbbbbbbbbbb")
    end

    it "falls back to hard cuts when no newline is present" do
      kernel = described_class.allocate
      text = "x" * 23

      chunks = kernel.send(:split_message, text, 10)

      expect(chunks).to eq(["x" * 10, "x" * 10, "x" * 3])
    end
  end
end
