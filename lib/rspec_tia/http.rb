require 'json'
require 'net/http'
require 'openssl'
require 'uri'

module RspecTia
  # Minimal GET client for CI APIs.
  class Http
    OPEN_TIMEOUT_SECONDS = 10
    READ_TIMEOUT_SECONDS = 30

    # Wrap transport exceptions in Error so callers can handle failures at the job level.
    NETWORK_ERRORS = [
      Timeout::Error, # Parent of Net::OpenTimeout and Net::ReadTimeout.
      SystemCallError, # Parent of errors such as Errno::ECONNRESET and Errno::ECONNREFUSED.
      SocketError,
      IOError,
      OpenSSL::SSL::SSLError,
    ].freeze

    class Error < StandardError; end

    # Indicates a missing artifact, such as an expired artifact or a nonexistent process filename.
    # Distinguish this from transient transport failures when deciding whether to stop fetching.
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
