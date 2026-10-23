require 'fileutils'
require 'json'
require 'set'
require 'stringio'
require 'time'
require 'zlib'

module RspecTia
  # specファイルと、そのspecが実行したソースファイルの対応表。
  #
  # 問い合わせは常に「変更されたソースファイル -> 実行すべきspec」の向きなので、
  # 内部では逆引き（source -> Set(spec)）で保持する。
  class Map
    FORMAT_VERSION = 1

    class FormatError < StandardError; end

    attr_reader :generated_at, :commit_sha

    class << self
      def load(path)
        new.tap { |map| map.load_hash(read_hash(path)) }
      end

      # 複数の断片（parallel_testsのプロセスごと・CIノードごとに出力される）を1つにまとめる
      def merge_files(paths)
        paths.reduce(new) { |merged, path| merged.merge!(load(path)) }
      end

      private

      def read_hash(path)
        raw = File.binread(path)
        raw = Zlib::GzipReader.new(StringIO.new(raw)).read if gzipped?(raw)
        JSON.parse(raw)
      end

      # 拡張子ではなくgzipのマジックナンバーで判定する。
      # CIのartifactは拡張子が保たれない経路を通ることがあるため
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
      # 断片ごとに生成時刻が異なるため、最も古いものを採用して鮮度判定を安全側に倒す
      @generated_at = [@generated_at, other.generated_at].compact.min
      @commit_sha ||= other.commit_sha
      self
    end

    # 生成時刻が不明な場合も「古い」とみなす（安全側）
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
      @generated_at = hash['generated_at'] && Time.iso8601(hash['generated_at'])
      @commit_sha = hash['commit_sha']
      self
    end
  end
end
