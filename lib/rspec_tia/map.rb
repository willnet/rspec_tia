require 'fileutils'
require 'json'
require 'set'
require 'stringio'
require 'time'
require 'zlib'

module RspecTia
  # Map spec files to the source files they execute.
  #
  # Queries always go from changed sources to affected specs,
  # so store dependencies as a reverse index: source -> Set(spec).
  class Map
    FORMAT_VERSION = 1

    class FormatError < StandardError; end

    attr_reader :generated_at, :commit_sha

    class << self
      # Report corrupted files, such as truncated gzip or JSON, as FormatError with the path
      # so that the CLI can fail with a diagnostic instead of a backtrace.
      def load(path)
        new.tap { |map| map.load_hash(read_hash(path)) }
      rescue FormatError, JSON::ParserError, Zlib::Error => e
        raise FormatError, "Invalid map file: #{path}: #{e.message}"
      end

      # Merge fragments produced by parallel_tests processes and CI nodes.
      def merge_files(paths)
        paths.reduce(new) { |merged, path| merged.merge!(load(path)) }
      end

      private

      def read_hash(path)
        raw = File.binread(path)
        raw = Zlib::GzipReader.new(StringIO.new(raw)).read if gzipped?(raw)
        JSON.parse(raw)
      end

      # Detect gzip using its magic bytes rather than the filename extension.
      # CI artifact transfer paths may not preserve extensions.
      def gzipped?(raw)
        raw.getbyte(0) == 0x1f && raw.getbyte(1) == 0x8b
      end
    end

    def initialize(generated_at: nil, commit_sha: nil)
      @specs = Set.new
      @edges = {}
      @generated_at = generated_at
      @commit_sha = commit_sha
    end

    def add(spec, sources)
      @specs << spec
      sources.each do |source|
        (@edges[source] ||= Set.new) << spec
      end
      self
    end

    def specs_for(source)
      @edges[source] || Set.new
    end

    def known_source?(source)
      @edges.key?(source)
    end

    def specs
      @specs
    end

    def sources
      @edges.keys
    end

    def empty?
      @specs.empty?
    end

    def merge!(other)
      @specs.merge(other.specs)
      other.sources.each do |source|
        (@edges[source] ||= Set.new).merge(other.specs_for(source))
      end
      # Use the oldest fragment timestamp to keep freshness checks conservative.
      @generated_at = [@generated_at, other.generated_at].compact.min
      @commit_sha ||= other.commit_sha
      self
    end

    # Treat an unknown generation timestamp as stale to stay conservative.
    def stale?(max_age_days:, now: Time.now)
      return true if @generated_at.nil?

      now - @generated_at > max_age_days * 24 * 60 * 60
    end

    def dump(path)
      json = JSON.generate(to_h)
      FileUtils.mkdir_p(File.dirname(path))
      if path.end_with?('.gz')
        File.open(path, 'wb') { |f| Zlib::GzipWriter.wrap(f) { |gz| gz.write(json) } }
      else
        File.write(path, json)
      end
      path
    end

    def to_h
      spec_list = @specs.to_a.sort
      spec_index = spec_list.each_with_index.to_h
      source_list = @edges.keys.sort

      {
        'format_version' => FORMAT_VERSION,
        'generated_at' => @generated_at&.utc&.iso8601,
        'commit_sha' => @commit_sha,
        'specs' => spec_list,
        'sources' => source_list,
        'edges' => source_list.map { |source| @edges[source].map { |spec| spec_index[spec] }.sort },
      }
    end

    def load_hash(hash)
      raise FormatError, 'map must be an object' unless hash.is_a?(Hash)

      version = hash['format_version']
      raise FormatError, "unsupported format_version: #{version.inspect}" unless version == FORMAT_VERSION

      spec_list = hash['specs']
      source_list = hash['sources']
      edges = hash['edges']
      valid_paths = [spec_list, source_list].all? do |paths|
        paths.is_a?(Array) && paths.all? { |path| path.is_a?(String) } && paths.uniq.size == paths.size
      end
      unless valid_paths
        raise FormatError, 'specs and sources must be arrays of unique strings'
      end
      valid_edges = edges.is_a?(Array) && edges.size == source_list.size && edges.all? do |ids|
        ids.is_a?(Array) && ids.all? { |id| id.is_a?(Integer) && id >= 0 && id < spec_list.size }
      end
      unless valid_edges
        raise FormatError, 'edges must contain one array of valid spec indices per source'
      end

      @specs = Set.new(spec_list)
      @edges = {}
      source_list.each_with_index do |source, i|
        @edges[source] = Set.new(edges[i].map { |id| spec_list[id] })
      end
      @generated_at = parse_time(hash['generated_at'])
      @commit_sha = hash['commit_sha']
      self
    end

    private

    def parse_time(value)
      return nil if value.nil?

      Time.iso8601(value)
    rescue ArgumentError, TypeError
      raise FormatError, "invalid generated_at: #{value.inspect}"
    end
  end
end
