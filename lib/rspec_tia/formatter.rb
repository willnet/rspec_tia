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
    RSpec::Core::Formatters.register self, :start, :example_group_started, :example_group_finished, :example_started, :stop

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

    # group開始通知はbefore(:context)より先、終了通知はafter(:context)より後に届く。
    def example_group_started(notification)
      switch_spec(relative(group_spec_path(notification.group)))
    end

    def example_group_finished(notification)
      return unless notification.group.parent_groups.size == 1

      flush
      @current_spec = nil
    end

    def example_started(notification)
      switch_spec(relative(spec_path_of(notification.example)))
    end

    def stop(notification)
      flush
      @map.specs.each { |spec| @map.add(spec, (@suite_sources || []).to_a) }
      if notification.failed_examples.any? || RSpec.world.non_example_failure
        # 失敗したhook・fail-fast等で未実行の経路を含むマップは鮮度判定を通さない。
        @map.load_hash(@map.to_h.merge('generated_at' => Time.at(0).utc.iso8601))
        warn '[rspec_tia] Test run failed; saving the generated map as stale'
      end
      @map.dump(fragment_path)
    end

    private

    def build_rails_support
      return nil unless @config.rails_enabled? && @config.active_record_enabled?
      return nil unless RailsSupport.available?

      RailsSupport.new(root: @root).subscribe
    end

    def switch_spec(spec)
      return if spec == @current_spec

      flush
      @current_spec = spec
    end

    def spec_path_of(example)
      group_spec_path(example.example_group)
    end

    def group_spec_path(group)
      # shared examples の定義位置ではなく、実行可能な最上位groupのspecを使う。
      metadata = group.parent_groups.last.metadata
      metadata[:absolute_file_path] || metadata[:file_path]
    end

    def relative(path)
      absolute = File.expand_path(path.to_s.sub(%r{\A\./}, ''), @config.root)
      absolute.start_with?(@root) ? absolute.delete_prefix(@root) : absolute
    end

    def flush
      result = Coverage.result(stop: false, clear: true)
      touched = @rails_support ? @rails_support.flush : []
      sources = project_files(result) + touched
      if @current_spec.nil?
        # before/after(:suite)の依存は最初・最後のspecへ偏らせず全specへ付ける。
        (@suite_sources ||= Set.new).merge(sources)
      else
        @map.add(@current_spec, sources)
      end
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
