require "json"
require_relative "runtime_helpers"

module Skein
  class Repl
    include RuntimeHelpers

    CHAT_ID = "cli"
    RATING_MAP = { "1" => -2, "2" => -1, "3" => 0, "4" => 1, "5" => 2 }.freeze

    # ANSI codes
    BOLD      = "\033[1m"
    DIM       = "\033[2m"
    ITALIC    = "\033[3m"
    RESET     = "\033[0m"
    CYAN      = "\033[36m"
    YELLOW    = "\033[33m"
    GREEN     = "\033[32m"
    RED       = "\033[31m"
    MAGENTA   = "\033[35m"
    BG_GRAY   = "\033[48;5;236m"  # Dark gray background for code blocks

    # Spinner frames
    SPINNER = %w[⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏].freeze

    def initialize
      @config    = Config.new
      @db        = DB.new(@config.db_path, busy_timeout_ms: @config.db_busy_timeout_ms)
      @events    = EventStore.new(@db)
      @tasks     = Task.new(db: @db, event_store: @events)
      @timers    = Timer.new(db: @db, event_store: @events)
      @embedder  = build_embedder
      @memory    = Memory.new(db: @db, event_store: @events, embedder: @embedder)
      @lessons   = Lesson.new(db: @db, event_store: @events)

      # SDK client + tool executor + skills
      tool_executor = ToolExecutor.new(memory: @memory, timers: @timers, config: @config)

      @skill_registry = SkillRegistry.new(
        context: skill_context, logger: method(:log)
      )
      @skill_registry.load_all!
      @skill_registry.register_tools!(tool_executor)

      sdk_client = SdkClient.new(
        config: @config, tool_executor: tool_executor,
        channel: self, logger: method(:log)
      )

      @agent = Agent.new(
        config: @config, db: @db, events: @events, tasks: @tasks,
        timers: @timers, memory: @memory, lessons: @lessons,
        sdk_client: sdk_client, tool_executor: tool_executor,
        skill_registry: @skill_registry,
        channel: self, logger: method(:log)
      )

      @running = true
      @streaming = false  # Whether we've received any stream tokens
      @spinner_thread = nil
      setup_signal_handlers!
    end

    def run
      puts "#{BOLD}Skein REPL#{RESET} #{DIM}(Claude Agent SDK)#{RESET}"
      puts "#{DIM}Type a message to chat with Claude. Ctrl+C to quit.#{RESET}\n\n"

      @agent.start_sdk

      while @running
        print "#{BOLD}#{CYAN}you>#{RESET} "
        input = gets
        break unless input
        input = input.strip
        next if input.empty?

        handle_input(input)
        puts
      end

      @agent.stop_sdk
      puts "\n#{DIM}Bye.#{RESET}"
    end

    # --- Channel Adapter Interface ---

    def send_reply(_chat_id, text)
      puts render_markdown(text)
    end

    # Streaming: print tokens progressively as they arrive
    def stream_text(_chat_id, text)
      if !@streaming
        stop_spinner!
        @streaming = true
      end
      print text
      $stdout.flush
    end

    # Called after streaming completes — just print a newline
    def stream_end(_chat_id)
      stop_spinner!
      @streaming = false
      puts
    end

    # Called by the SDK (via Agent) when a tool needs approval.
    # In the REPL, this is synchronous — ask the user directly.
    def request_approval(_chat_id, tool_name, tool_input)
      stop_spinner!
      puts
      puts "#{YELLOW}#{BOLD}Tool requiring approval:#{RESET}"
      puts "  #{BOLD}#{tool_name}#{RESET}"
      format_tool_input(tool_input).each { |line| puts "  #{DIM}#{line}#{RESET}" }
      print "#{YELLOW}Approve? [y/n]#{RESET} "
      answer = gets&.strip&.downcase

      if answer == "y" || answer == "yes"
        puts "#{GREEN}Approved.#{RESET}"
        start_spinner!  # Resume spinner while tool runs
        "allow"
      else
        puts "#{RED}Denied.#{RESET}"
        "deny"
      end
    end

    private

    def handle_input(input)
      @events.append(type: "cli_message_received", payload: { text: input })

      task_id = @tasks.create(source: "cli", chat_id: CHAT_ID, input_text: input)
      @tasks.transition!(task_id, "running")

      task = @tasks.find(task_id)
      print "#{BOLD}#{YELLOW}skein>#{RESET} "
      $stdout.flush
      @streaming = false
      start_spinner!

      @agent.process_task(task)

      prompt_for_rating(task_id)
    end

    # --- Spinner ---

    def start_spinner!
      @spinner_thread&.kill
      @spinner_thread = Thread.new do
        i = 0
        loop do
          print "\r#{BOLD}#{YELLOW}skein>#{RESET} #{DIM}#{SPINNER[i % SPINNER.size]} thinking...#{RESET}"
          $stdout.flush
          sleep 0.08
          i += 1
        end
      rescue StandardError
        # thread killed
      end
    end

    def stop_spinner!
      if @spinner_thread
        @spinner_thread.kill
        @spinner_thread = nil
        # Clear the spinner line and reprint the prompt
        print "\r#{BOLD}#{YELLOW}skein>#{RESET} \033[K"  # \033[K = clear to end of line
        $stdout.flush
      end
    end

    # --- Markdown Rendering (for non-streaming output) ---

    def render_markdown(text)
      lines = text.split("\n")
      in_code_block = false
      result = []

      lines.each do |line|
        if line.start_with?("```")
          in_code_block = !in_code_block
          if in_code_block
            lang = line.sub(/^```/, "").strip
            result << "#{DIM}#{BG_GRAY}#{lang.empty? ? '' : " #{lang} "}#{RESET}"
          else
            result << "#{DIM}#{RESET}"
          end
        elsif in_code_block
          result << "#{BG_GRAY}  #{line}#{RESET}"
        else
          result << render_markdown_line(line)
        end
      end

      result.join("\n")
    end

    def render_markdown_line(line)
      # Headers
      if line.start_with?("### ")
        return "#{BOLD}#{MAGENTA}#{line.sub(/^### /, '')}#{RESET}"
      elsif line.start_with?("## ")
        return "#{BOLD}#{MAGENTA}#{line.sub(/^## /, '')}#{RESET}"
      elsif line.start_with?("# ")
        return "#{BOLD}#{MAGENTA}#{line.sub(/^# /, '')}#{RESET}"
      end

      # Bullet lists — bold the dash
      if line.match?(/^\s*[-*] /)
        line = line.sub(/^(\s*)([-*])/) { "#{$1}#{BOLD}#{$2}#{RESET}" }
      end

      # Inline code
      line = line.gsub(/`([^`]+)`/) { "#{BG_GRAY} #{$1} #{RESET}" }

      # Bold
      line = line.gsub(/\*\*([^*]+)\*\*/) { "#{BOLD}#{$1}#{RESET}" }

      # Italic
      line = line.gsub(/(?<!\*)\*([^*]+)\*(?!\*)/) { "#{ITALIC}#{$1}#{RESET}" }

      line
    end

    # --- Tool Input Formatting ---

    def format_tool_input(tool_input)
      return [tool_input.to_s] unless tool_input.is_a?(Hash)

      tool_input.map do |key, value|
        if value.is_a?(String) && value.length > 80
          "#{key}: #{value[0..77]}..."
        else
          "#{key}: #{value}"
        end
      end
    end

    # --- Rating ---

    def prompt_for_rating(task_id)
      print "#{DIM}  [rate 1-5 or enter to skip]#{RESET} "
      $stdout.flush
      input = gets&.strip
      return if input.nil? || input.empty?

      delta = RATING_MAP[input]
      return unless delta

      @lessons.rate_for_task(task_id: task_id, delta: delta)
      puts "#{DIM}  [rated #{input}/5 — lessons adjusted]#{RESET}" unless delta.zero?
    rescue StandardError => e
      log "Rating error: #{e.message}"
      # Never break the REPL over a rating
    end

    def setup_signal_handlers!
      Signal.trap("INT") { @running = false }
    end

    def log(msg)
      # REPL uses dimmed output for system messages
      puts "#{DIM}  [#{msg}]#{RESET}"
    end
  end
end
