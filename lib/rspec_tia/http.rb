require 'json'
require 'net/http'
require 'openssl'
require 'uri'

module RspecTia
  # CI の API を叩くための最小の GET クライアント。
  class Http
    OPEN_TIMEOUT_SECONDS = 10
    READ_TIMEOUT_SECONDS = 30

    # 通信起因の例外。呼び出し側がジョブ単位でスキップできるよう Error に変換する
    NETWORK_ERRORS = [
      Timeout::Error, # Net::OpenTimeout / Net::ReadTimeout の親
      SystemCallError, # Errno::ECONNRESET / Errno::ECONNREFUSED 等の親
      SocketError,
      IOError,
      OpenSSL::SSL::SSLError,
    ].freeze

    class Error < StandardError; end

    # artifact が存在しない（プロセス数を超えたファイル名・期限切れ）ことを示す。
    # 一時的な通信障害と区別して、取得の打ち切り判定に使う
    class NotFound < Error; end

    def initialize(base_url:, headers: {})
      @base_url = base_url.to_s.chomp('/')
      @headers = headers
    end

    def get(path)
      uri = URI.parse("#{@base_url}#{path}")
      request = Net::HTTP::Get.new(uri)
      @headers.each { |key, value| request[key] = value }

      response = perform(uri, request)
      raise NotFound, "GET #{uri} not found: #{response.code} #{response.message}" if response.is_a?(Net::HTTPNotFound)
      raise Error, "GET #{uri} failed: #{response.code} #{response.message}" unless response.is_a?(Net::HTTPSuccess)

      response.body
    end

    def get_json(path)
      JSON.parse(get(path))
    end

    private

    def perform(uri, request)
      options = {
        use_ssl: uri.scheme == 'https',
        open_timeout: OPEN_TIMEOUT_SECONDS,
        read_timeout: READ_TIMEOUT_SECONDS,
      }
      Net::HTTP.start(uri.host, uri.port, **options) { |http| http.request(request) }
    rescue *NETWORK_ERRORS => e
      raise Error, "GET #{uri} failed: #{e.class}: #{e.message}"
    end
  end
end
