require "spec_helper"
require "skein/config"

RSpec.describe Skein::Config do
  describe "#chat_allowed?" do
    it "allows any chat when no allowlist" do
      ENV.delete("SKEIN_ALLOWED_CHAT_IDS")
      config = Skein::Config.new
      expect(config.chat_allowed?("12345")).to be_truthy
      expect(config.chat_allowed?("99999")).to be_truthy
    end

    it "filters with allowlist" do
      ENV["SKEIN_ALLOWED_CHAT_IDS"] = "111,222,333"
      config = Skein::Config.new
      expect(config.chat_allowed?("111")).to be_truthy
      expect(config.chat_allowed?("222")).to be_truthy
      expect(config.chat_allowed?("999")).to be_falsey
    ensure
      ENV.delete("SKEIN_ALLOWED_CHAT_IDS")
    end

    it "coerces integer to string" do
      ENV["SKEIN_ALLOWED_CHAT_IDS"] = "111"
      config = Skein::Config.new
      expect(config.chat_allowed?(111)).to be_truthy
    ensure
      ENV.delete("SKEIN_ALLOWED_CHAT_IDS")
    end

    it "handles spaces in list" do
      ENV["SKEIN_ALLOWED_CHAT_IDS"] = " 111 , 222 , 333 "
      config = Skein::Config.new
      expect(config.chat_allowed?("111")).to be_truthy
      expect(config.chat_allowed?("333")).to be_truthy
    ensure
      ENV.delete("SKEIN_ALLOWED_CHAT_IDS")
    end

    it "treats empty string as no allowlist" do
      ENV["SKEIN_ALLOWED_CHAT_IDS"] = ""
      config = Skein::Config.new
      expect(config.chat_allowed?("12345")).to be_truthy
    ensure
      ENV.delete("SKEIN_ALLOWED_CHAT_IDS")
    end
  end

  describe "defaults" do
    it "has default model" do
      config = Skein::Config.new
      expect(config.model).to eq("sonnet")
    end

    it "has default max_context_turns" do
      config = Skein::Config.new
      expect(config.max_context_turns).to eq(20)
    end

    it "has default embedding_model" do
      config = Skein::Config.new
      expect(config.embedding_model).to eq("sentence-transformers/all-MiniLM-L6-v2")
    end

    it "has embedding enabled by default" do
      config = Skein::Config.new
      expect(config.embedding_enabled).to eq(true)
    end

    it "has default notes_dir" do
      config = Skein::Config.new
      expect(config.notes_dir).to eq("docs/notes")
    end

    it "has default cli_path" do
      config = Skein::Config.new
      expect(config.cli_path).to eq(File.expand_path("~/.local/bin/claude"))
    end

    it "has default runtime timeouts and thresholds" do
      config = Skein::Config.new
      expect(config.task_timeout).to eq(300)
      expect(config.stale_task_timeout).to eq(300)
      expect(config.decompose_timeout).to eq(30)
      expect(config.extract_timeout).to eq(30)
      expect(config.summary_timeout).to eq(60)
      expect(config.consolidate_timeout).to eq(120)
      expect(config.approval_timeout).to eq(600)
      expect(config.approval_poll_timeout).to eq(5)
      expect(config.approval_input_preview_length).to eq(500)
      expect(config.decomposition_min_length).to eq(80)
      expect(config.sdk_max_turns).to eq(50)
      expect(config.consolidation_safety_ratio).to eq(0.3)
      expect(config.event_retention_days).to eq(30)
      expect(config.db_busy_timeout_ms).to eq(5000)
      expect(config.telegram_open_timeout).to eq(10)
      expect(config.telegram_post_read_timeout).to eq(30)
      expect(config.telegram_poll_read_timeout_buffer).to eq(5)
      expect(config.embedding_backfill_batch_size).to eq(50)
    end
  end

  describe "embedding config" do
    it "disables embedding via env" do
      ENV["SKEIN_EMBEDDING_ENABLED"] = "false"
      config = Skein::Config.new
      expect(config.embedding_enabled).to eq(false)
    ensure
      ENV.delete("SKEIN_EMBEDDING_ENABLED")
    end

    it "uses custom embedding model from env" do
      ENV["SKEIN_EMBEDDING_MODEL"] = "custom/model-name"
      config = Skein::Config.new
      expect(config.embedding_model).to eq("custom/model-name")
    ensure
      ENV.delete("SKEIN_EMBEDDING_MODEL")
    end
  end

  describe "constructor overrides" do
    it "takes precedence over defaults" do
      config = Skein::Config.new(model: "opus", max_context_turns: 50, summary_threshold: 10)
      expect(config.model).to eq("opus")
      expect(config.max_context_turns).to eq(50)
      expect(config.summary_threshold).to eq(10)
      expect(Skein::Config.new.model).to eq("sonnet")
    end

    it "takes precedence over env" do
      ENV["SKEIN_MODEL"] = "haiku"
      config = Skein::Config.new(model: "opus")
      expect(config.model).to eq("opus")
      config_env = Skein::Config.new
      expect(config_env.model).to eq("haiku")
    ensure
      ENV.delete("SKEIN_MODEL")
    end

    it "takes precedence for cli_path" do
      ENV["SKEIN_CLI_PATH"] = "/tmp/env-claude"
      config = Skein::Config.new(cli_path: "/tmp/override-claude")
      expect(config.cli_path).to eq("/tmp/override-claude")
    ensure
      ENV.delete("SKEIN_CLI_PATH")
    end

    it "takes precedence for task and stale timeouts" do
      ENV["SKEIN_TASK_TIMEOUT"] = "999"
      ENV["SKEIN_STALE_TASK_TIMEOUT"] = "888"
      config = Skein::Config.new(task_timeout: 111, stale_task_timeout: 222)
      expect(config.task_timeout).to eq(111)
      expect(config.stale_task_timeout).to eq(222)
    ensure
      ENV.delete("SKEIN_TASK_TIMEOUT")
      ENV.delete("SKEIN_STALE_TASK_TIMEOUT")
    end
  end

  describe "#cli_path" do
    it "uses custom cli_path from env" do
      ENV["SKEIN_CLI_PATH"] = "/tmp/custom-claude"
      config = Skein::Config.new
      expect(config.cli_path).to eq("/tmp/custom-claude")
    ensure
      ENV.delete("SKEIN_CLI_PATH")
    end
  end

  describe "runtime timeout env config" do
    it "reads runtime values from env" do
      ENV["SKEIN_TASK_TIMEOUT"] = "301"
      ENV["SKEIN_STALE_TASK_TIMEOUT"] = "302"
      ENV["SKEIN_DECOMPOSE_TIMEOUT"] = "33"
      ENV["SKEIN_EXTRACT_TIMEOUT"] = "34"
      ENV["SKEIN_SUMMARY_TIMEOUT"] = "61"
      ENV["SKEIN_CONSOLIDATE_TIMEOUT"] = "121"
      ENV["SKEIN_APPROVAL_TIMEOUT"] = "601"
      ENV["SKEIN_APPROVAL_POLL_TIMEOUT"] = "6"
      ENV["SKEIN_APPROVAL_INPUT_PREVIEW_LENGTH"] = "550"
      ENV["SKEIN_DECOMPOSITION_MIN_LENGTH"] = "81"
      ENV["SKEIN_SDK_MAX_TURNS"] = "51"
      ENV["SKEIN_CONSOLIDATION_SAFETY_RATIO"] = "0.4"
      ENV["SKEIN_EVENT_RETENTION_DAYS"] = "31"
      ENV["SKEIN_DB_BUSY_TIMEOUT_MS"] = "5001"
      ENV["SKEIN_TELEGRAM_OPEN_TIMEOUT"] = "11"
      ENV["SKEIN_TELEGRAM_POST_READ_TIMEOUT"] = "31"
      ENV["SKEIN_TELEGRAM_POLL_READ_TIMEOUT_BUFFER"] = "6"
      ENV["SKEIN_EMBEDDING_BACKFILL_BATCH_SIZE"] = "51"

      config = Skein::Config.new
      expect(config.task_timeout).to eq(301)
      expect(config.stale_task_timeout).to eq(302)
      expect(config.decompose_timeout).to eq(33)
      expect(config.extract_timeout).to eq(34)
      expect(config.summary_timeout).to eq(61)
      expect(config.consolidate_timeout).to eq(121)
      expect(config.approval_timeout).to eq(601)
      expect(config.approval_poll_timeout).to eq(6)
      expect(config.approval_input_preview_length).to eq(550)
      expect(config.decomposition_min_length).to eq(81)
      expect(config.sdk_max_turns).to eq(51)
      expect(config.consolidation_safety_ratio).to eq(0.4)
      expect(config.event_retention_days).to eq(31)
      expect(config.db_busy_timeout_ms).to eq(5001)
      expect(config.telegram_open_timeout).to eq(11)
      expect(config.telegram_post_read_timeout).to eq(31)
      expect(config.telegram_poll_read_timeout_buffer).to eq(6)
      expect(config.embedding_backfill_batch_size).to eq(51)
    ensure
      ENV.delete("SKEIN_TASK_TIMEOUT")
      ENV.delete("SKEIN_STALE_TASK_TIMEOUT")
      ENV.delete("SKEIN_DECOMPOSE_TIMEOUT")
      ENV.delete("SKEIN_EXTRACT_TIMEOUT")
      ENV.delete("SKEIN_SUMMARY_TIMEOUT")
      ENV.delete("SKEIN_CONSOLIDATE_TIMEOUT")
      ENV.delete("SKEIN_APPROVAL_TIMEOUT")
      ENV.delete("SKEIN_APPROVAL_POLL_TIMEOUT")
      ENV.delete("SKEIN_APPROVAL_INPUT_PREVIEW_LENGTH")
      ENV.delete("SKEIN_DECOMPOSITION_MIN_LENGTH")
      ENV.delete("SKEIN_SDK_MAX_TURNS")
      ENV.delete("SKEIN_CONSOLIDATION_SAFETY_RATIO")
      ENV.delete("SKEIN_EVENT_RETENTION_DAYS")
      ENV.delete("SKEIN_DB_BUSY_TIMEOUT_MS")
      ENV.delete("SKEIN_TELEGRAM_OPEN_TIMEOUT")
      ENV.delete("SKEIN_TELEGRAM_POST_READ_TIMEOUT")
      ENV.delete("SKEIN_TELEGRAM_POLL_READ_TIMEOUT_BUFFER")
      ENV.delete("SKEIN_EMBEDDING_BACKFILL_BATCH_SIZE")
    end

    it "defaults stale_task_timeout to task_timeout when not set" do
      ENV["SKEIN_TASK_TIMEOUT"] = "412"
      ENV.delete("SKEIN_STALE_TASK_TIMEOUT")
      config = Skein::Config.new
      expect(config.task_timeout).to eq(412)
      expect(config.stale_task_timeout).to eq(412)
    ensure
      ENV.delete("SKEIN_TASK_TIMEOUT")
      ENV.delete("SKEIN_STALE_TASK_TIMEOUT")
    end
  end

  describe "#notes_dir" do
    it "uses custom notes_dir from env" do
      ENV["SKEIN_NOTES_DIR"] = "/tmp/my-notes"
      config = Skein::Config.new
      expect(config.notes_dir).to eq("/tmp/my-notes")
    ensure
      ENV.delete("SKEIN_NOTES_DIR")
    end
  end

  describe "#auto_approve?" do
    it "has no auto approve by default" do
      ENV.delete("SKEIN_AUTO_APPROVE")
      config = Skein::Config.new
      expect(config.auto_approve_rules).to eq([])
      expect(config.auto_approve?("Bash", { "command" => "ls" })).to be_falsey
    end

    it "approves simple tool name" do
      ENV["SKEIN_AUTO_APPROVE"] = "Bash"
      config = Skein::Config.new
      expect(config.auto_approve?("Bash", { "command" => "rm -rf /" })).to be_truthy
      expect(config.auto_approve?("Write", { "file_path" => "/tmp/x" })).to be_falsey
    ensure
      ENV.delete("SKEIN_AUTO_APPROVE")
    end

    it "approves multiple tools" do
      ENV["SKEIN_AUTO_APPROVE"] = "Bash, Write, Edit"
      config = Skein::Config.new
      expect(config.auto_approve?("Bash", {})).to be_truthy
      expect(config.auto_approve?("Write", {})).to be_truthy
      expect(config.auto_approve?("Edit", {})).to be_truthy
      expect(config.auto_approve?("Delete", {})).to be_falsey
    ensure
      ENV.delete("SKEIN_AUTO_APPROVE")
    end

    it "approves wildcard" do
      ENV["SKEIN_AUTO_APPROVE"] = "*"
      config = Skein::Config.new
      expect(config.auto_approve?("Bash", {})).to be_truthy
      expect(config.auto_approve?("Write", {})).to be_truthy
      expect(config.auto_approve?("AnyTool", {})).to be_truthy
    ensure
      ENV.delete("SKEIN_AUTO_APPROVE")
    end

    it "approves with input pattern" do
      ENV["SKEIN_AUTO_APPROVE"] = "Bash:ls *"
      config = Skein::Config.new
      expect(config.auto_approve?("Bash", { "command" => "ls -la" })).to be_truthy
      expect(config.auto_approve?("Bash", { "command" => "rm -rf /" })).to be_falsey
    ensure
      ENV.delete("SKEIN_AUTO_APPROVE")
    end

    it "approves write path pattern" do
      ENV["SKEIN_AUTO_APPROVE"] = "Write:docs/*"
      config = Skein::Config.new
      expect(config.auto_approve?("Write", { "file_path" => "docs/notes/todo.md" })).to be_truthy
      expect(config.auto_approve?("Write", { "file_path" => "lib/skein/agent.rb" })).to be_falsey
    ensure
      ENV.delete("SKEIN_AUTO_APPROVE")
    end

    it "handles mixed rules" do
      ENV["SKEIN_AUTO_APPROVE"] = "Bash:ls *,Write:docs/*,Edit"
      config = Skein::Config.new
      expect(config.auto_approve?("Bash", { "command" => "ls -la" })).to be_truthy
      expect(config.auto_approve?("Bash", { "command" => "rm -rf /" })).to be_falsey
      expect(config.auto_approve?("Write", { "file_path" => "docs/README.md" })).to be_truthy
      expect(config.auto_approve?("Write", { "file_path" => "lib/secret.rb" })).to be_falsey
      expect(config.auto_approve?("Edit", { "file_path" => "anything.rb" })).to be_truthy
    ensure
      ENV.delete("SKEIN_AUTO_APPROVE")
    end
  end
end
