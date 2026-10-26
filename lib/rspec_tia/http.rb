require 'json'
require 'net/http'
require 'openssl'
require 'uri'

module RspecTia
  # Minimal GET client for CI APIs.
  class Http
    OPEN_TIMEOUT_SECONDS = 10
    READ_TIMEOUT_SECONDS = 30
    MAX_REDIRECTS = 5

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

    # Report errors with the requested URI, not a redirect target, to keep signed CDN URLs out of CI logs.
    def get(path)
      uri = URI.parse("#{@base_url}#{path}")
      response = follow_redirects(uri)
      raise NotFound, "GET #{uri} not found: #{response.code} #{response.message}" if response.is_a?(Net::HTTPNotFound)
      raise Error, "GET #{uri} failed: #{response.code} #{response.message}" unless response.is_a?(Net::HTTPSuccess)

      response.body
    rescue *NETWORK_ERRORS => e
      raise Error, "GET #{uri} failed: #{e.class}: #{e.message}"
    end

    def get_json(path)
      JSON.parse(get(path))
    end

    private

    # GitLab.com may redirect artifact downloads through a CDN.
    def follow_redirects(uri)
      target = uri
      headers = @headers
      (MAX_REDIRECTS + 1).times do
        response = perform(target, headers)
        return response unless response.is_a?(Net::HTTPRedirection)

        location = response['location']
        raise Error, "GET #{uri} failed: #{response.code} without a Location header" if location.to_s.empty?

        next_target = URI.join(target.to_s, location)
        raise Error, "GET #{uri} failed: redirected to a non-HTTP location" unless next_target.is_a?(URI::HTTP)

        # Never forward the API token to another origin, such as object storage with signed URLs.
        headers = {} unless origin(next_target) == origin(target)
        target = next_target
      end
      raise Error, "GET #{uri} failed: more than #{MAX_REDIRECTS} redirects"
    rescue URI::Error => e
      raise Error, "GET #{uri} failed: invalid redirect location: #{e.message}"
    end

    def origin(uri) = [uri.scheme, uri.host, uri.port]

    def perform(uri, headers)
      request = Net::HTTP::Get.new(uri)
      headers.each { |key, value| request[key] = value }
      options = {
        use_ssl: uri.scheme == 'https',
        open_timeout: OPEN_TIMEOUT_SECONDS,
        read_timeout: READ_TIMEOUT_SECONDS,
      }
      Net::HTTP.start(uri.host, uri.port, **options) { |http| http.request(request) }
    end
  end
end
