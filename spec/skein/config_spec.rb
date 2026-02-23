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
