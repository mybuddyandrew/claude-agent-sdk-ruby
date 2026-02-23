require "net/http"
require "uri"
require "json"

module Skein
  module Activities
    class Telegram
      BASE_URL = "https://api.telegram.org"

      def initialize(token:)
        @token = token
        @offset = 0
      end

      def poll(timeout: 30)
        uri = api_uri("getUpdates", offset: @offset, timeout: timeout, allowed_updates: '["message"]')
        response = get(uri, read_timeout: timeout + 5)
        return [] unless response

        data = JSON.parse(response.body)
        return [] unless data["ok"] && data["result"]

        updates = data["result"]
        updates.each { |u| @offset = u["update_id"] + 1 }
        updates
      rescue JSON::ParserError, StandardError => e
        $stderr.puts "[Telegram] poll error: #{e.class}: #{e.message}"
        []
      end

      def send_message(chat_id:, text:, parse_mode: nil)
        uri = api_uri("sendMessage")
        body = { chat_id: chat_id, text: text }
        body[:parse_mode] = parse_mode if parse_mode

        response = post(uri, body)
        return nil unless response

        data = JSON.parse(response.body)
        unless data["ok"]
          $stderr.puts "[Telegram] send_message failed: #{data['description']}"
          return nil
        end
        data["result"]
      rescue StandardError => e
        $stderr.puts "[Telegram] send error: #{e.class}: #{e.message}"
        raise
      end

      private

      def api_uri(method, params = {})
        uri = URI("#{BASE_URL}/bot#{@token}/#{method}")
        uri.query = URI.encode_www_form(params) unless params.empty?
        uri
      end

      def get(uri, read_timeout: 35)
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = true
        http.open_timeout = 10
        http.read_timeout = read_timeout

        request = Net::HTTP::Get.new(uri)
        http.request(request)
      rescue Net::OpenTimeout, Net::ReadTimeout, Errno::ECONNREFUSED, SocketError => e
        $stderr.puts "[Telegram] connection error: #{e.class}: #{e.message}"
        nil
      end

      def post(uri, body)
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = true
        http.open_timeout = 10
        http.read_timeout = 30

        request = Net::HTTP::Post.new(uri)
        request["Content-Type"] = "application/json"
        request.body = JSON.generate(body)
        http.request(request)
      rescue Net::OpenTimeout, Net::ReadTimeout, Errno::ECONNREFUSED, SocketError => e
        $stderr.puts "[Telegram] connection error: #{e.class}: #{e.message}"
        nil
      end
    end
  end
end
