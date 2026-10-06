require 'coverage'
require 'rspec/core'
require 'rspec/core/formatters'
require 'set'
require 'rspec_tia'
require 'rspec_tia/rails_support'

module RspecTia
  # specファイル単位でカバレッジを切り出し、依存マップの断片を書き出す RSpec フォーマッタ。
  #
  #   RUBYOPT="-rrspec_tia/boot" bundle exec rspec \
  #     --require rspec_tia/formatter --format RspecTia::Formatter
  #
  # 仕組み
  #   - suite開始時に1回 clear する。eager_load を有効にしていると boot 時点で
  #     全クラス定義行が実行済みになるため、これを捨てないと全specが全ファイルに依存してしまう
  #   - specファイルが切り替わるたびに Coverage.result(clear: true) を取る。
  #     clear 付きで取れば「返ってきた結果 = そのspecが触ったファイル」になり、差分計算が要らない
  #
  # 粒度がspecファイル単位なのは、example単位にすると呼び出し回数が2桁増えるため。
  # specファイル単位なら実測で 25〜31ms × specファイル数に収まる。
  class Formatter
    RSpec::Core::Formatters.register self, :start, :example_started, :stop

    def initialize(_output)
      @config = RspecTia.config
      @root = @config.root.end_with?('/') ? @config.root : "#{@config.root}/"
      @map = Map.new(generated_at: Time.now, commit_sha: RspecTia.commit_sha)
      @current_spec = nil
      @rails_support = nil
    end

    def start(_notification)
      @rails_support ||= build_rails_support
      # boot（とspecファイルのロード）で実行された行を捨てる
      Coverage.result(stop: false, clear: true)
      @rails_support&.flush
    end

    def example_started(notification)
      spec = relative(spec_path_of(notification.example))
      return if spec == @current_spec

      flush
      @current_spec = spec
    end

    def stop(_notification)
      flush
      @map.dump(fragment_path)
    end

    private

    def build_rails_support
      return nil unless @config.rails_enabled? && @config.active_record_enabled?
      return nil unless RailsSupport.available?

      RailsSupport.new(root: @root).subscribe
    end

    def spec_path_of(example)
      # shared examples の定義位置ではなく、実行可能な最上位groupのspecを使う。
      metadata = example.example_group.parent_groups.last.metadata
      metadata[:absolute_file_path] || metadata[:file_path]
    end

    def relative(path)
      absolute = File.expand_path(path.to_s.sub(%r{\A\./}, ''), @config.root)
      absolute.start_with?(@root) ? absolute.delete_prefix(@root) : absolute
    end

    def flush
      result = Coverage.result(stop: false, clear: true)
      touched = @rails_support ? @rails_support.flush : []
      return if @current_spec.nil?

      @map.add(@current_spec, project_files(result) + touched)
    end

    def project_files(result)
      result.filter_map do |path, coverage|
        next unless path.start_with?(@root)

        lines = coverage[:lines]
        next if lines.nil?
        next unless lines.any? { |hits| hits.to_i.positive? }

        path.delete_prefix(@root)
      end
    end

    # parallel_tests のプロセスごと・CIのノードごとに別ファイルへ書き出す。
    # 同じ名前に書くとプロセス間で上書きし合って依存が欠落する
    def fragment_path
      return ENV['RSPEC_TIA_FRAGMENT_PATH'] if ENV['RSPEC_TIA_FRAGMENT_PATH']

      File.join(@config.map_fragment_dir, "map-#{fragment_suffix}.json.gz")
    end

    def fragment_suffix
      parts = [ENV['CI_NODE_INDEX'], ENV['TEST_ENV_NUMBER']].map { |v| v.to_s.empty? ? nil : v }.compact
      parts.empty? ? Process.pid.to_s : parts.join('-')
    end
  end
end
