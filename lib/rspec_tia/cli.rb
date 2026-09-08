require 'optparse'
require 'rspec_tia'
require 'rspec_tia/audit'
require 'rspec_tia/ci'
require 'rspec_tia/junit_report'
require 'rspec_tia/metrics'

module RspecTia
  class Cli
    USAGE = <<~TEXT.freeze
      使い方: rspec-tia <コマンド> [オプション]

        select                実行すべきspecを標準出力に列挙する（全実行なら full_run_token を1行）
        map merge             断片マップをまとめて1つのマップにする
        map fetch             CIから断片マップを取得してまとめる
        audit                 全実行の結果と予測を突き合わせ、取りこぼしを検出する
        doctor                設定と環境の妥当性を確認する
        version               バージョンを表示する

      共通オプション:
        --config PATH         設定ファイル（既定: .rspec_tia.yml）
        --root PATH           プロジェクトルート（既定: カレントディレクトリ）
    TEXT

    def self.start(argv)
      new(argv).run
    end

    def initialize(argv)
      @argv = argv.dup
      @options = {}
    end

    def run
      command = @argv.shift
      case command
      when 'select' then select
      when 'map' then map_command
      when 'audit' then audit
      when 'doctor' then doctor
      when 'version', '--version', '-v' then puts(VERSION) || 0
      when nil, 'help', '--help', '-h' then puts(USAGE) || 0
      else
        warn "未知のコマンドです: #{command}\n\n#{USAGE}"
        1
      end
    rescue Ci::UnknownAdapterError, Map::FormatError, Errno::ENOENT => e
      warn "[rspec_tia] #{e.message}"
      1
    end

    private

    def select
      parse!('select') do |parser|
        parser.on('--junit-dir DIR', '実測時間で削減率を出すための junit.xml 置き場') { |v| @options[:junit_dir] = v }
        parser.on('--metrics PATH', 'メトリクスの出力先') { |v| @options[:metrics] = v }
        parser.on('--changed-files-from PATH', 'CIから取らずに変更ファイル一覧を読む（- で標準入力）') do |v|
          @options[:changed_files_from] = v
        end
      end

      result = Predictor.new(config: config, map: load_map).call(select_context)
      puts(result.full_run? ? config.full_run_token : result.specs)

      metrics = Metrics.new(config: config, result: result, junit_report: junit_report(@options[:junit_dir]))
      metrics.write(@options[:metrics] || config.metrics_path)
      warn metrics.summary
      0
    end

    def map_command
      case @argv.shift
      when 'merge' then map_merge
      when 'fetch' then map_fetch
      else
        warn "使い方: rspec-tia map [merge|fetch]"
        1
      end
    end

    def map_merge
      parse!('map merge') do |parser|
        parser.on('--fragments DIR', '断片の置き場') { |v| @options[:fragments] = v }
        parser.on('-o', '--output PATH', 'まとめたマップの出力先') { |v| @options[:output] = v }
      end

      dir = @options[:fragments] || config.map_fragment_dir
      fragments = Dir.glob(File.join(dir, '*.json*')).sort
      if fragments.empty?
        warn "[rspec_tia] 断片が見つかりません: #{dir}"
        return 1
      end

      map = Map.merge_files(fragments)
      path = map.dump(@options[:output] || config.map_path)
      warn format('[rspec_tia] 断片%d件をまとめました -> %s (spec %d件 / source %d件)',
                  fragments.size, path, map.specs.size, map.sources.size)
      0
    end

    def map_fetch
      parse!('map fetch') do |parser|
        parser.on('--dest DIR', '断片のダウンロード先') { |v| @options[:dest] = v }
        parser.on('--[no-]merge', 'ダウンロード後にまとめる（既定: する）') { |v| @options[:merge] = v }
      end

      dest = @options[:dest] || config.map_fragment_dir
      fragments = Ci.build(config).fetch_map_fragments(dest)
      if fragments.empty?
        warn '[rspec_tia] 断片を取得できませんでした（予測は全実行にフォールバックします）'
        return 0
      end

      warn "[rspec_tia] 断片#{fragments.size}件を取得しました -> #{dest}"
      return 0 if @options[:merge] == false

      @options[:fragments] = dest
      map_merge_from(fragments)
    end

    def map_merge_from(fragments)
      map = Map.merge_files(fragments)
      path = map.dump(@options[:output] || config.map_path)
      warn format('[rspec_tia] マップを作成しました -> %s (spec %d件 / source %d件)',
                  path, map.specs.size, map.sources.size)
      0
    end

    def audit
      parse!('audit') do |parser|
        parser.on('--junit DIR', '全実行の junit.xml 置き場') { |v| @options[:junit] = v }
        parser.on('--predicted PATH', '予測が出力したspec一覧（1行1パス）') { |v| @options[:predicted] = v }
      end

      missing = %i(junit predicted).reject { |key| @options[key] }
      unless missing.empty?
        warn "[rspec_tia] --#{missing.join(' と --')} は必須です"
        return 1
      end

      predicted = File.readlines(@options[:predicted], chomp: true).reject(&:empty?)
      result = Audit.new(junit_report: JunitReport.load_dir(@options[:junit]), predicted_specs: predicted).call
      warn result.summary
      result.ok? ? 0 : 1
    end

    def doctor
      parse!('doctor')
      checks = [
        ['設定ファイル', config_status],
        ['specの検出', spec_status],
        ['カバレッジマップ', map_status],
        ['CIアダプタ', adapter_status],
        ['静的マッピング', static_mapping_status],
      ]
      ok = checks.all? { |_, (result, _)| result }
      checks.each { |name, (result, detail)| puts format('%s %-16s %s', result ? 'ok  ' : 'NG  ', name, detail) }
      ok ? 0 : 1
    end

    def config_status
      path = @options[:config] || File.join(root, Configuration::DEFAULT_PATH)
      File.exist?(path) ? [true, path] : [false, "#{path} が見つかりません（既定値で動作します）"]
    end

    def spec_status
      count = config.all_specs.size
      [count.positive?, "#{config.spec_glob} -> #{count}件"]
    end

    def map_status
      return [false, "#{config.map_path} がありません"] unless File.exist?(config.map_path)

      map = Map.load(config.map_path)
      stale = map.stale?(max_age_days: config.map_max_age_days)
      detail = "spec #{map.specs.size}件 / source #{map.sources.size}件 / 生成 #{map.generated_at&.utc&.iso8601 || '不明'}"
      [!stale, stale ? "#{detail}（古い）" : detail]
    end

    def adapter_status
      adapter = Ci.build(config)
      [true, "#{adapter.class.name}（MR: #{adapter.merge_request?}）"]
    rescue Ci::UnknownAdapterError => e
      [false, e.message]
    end

    def static_mapping_status
      StaticMapping.new(config.static_mapping_rules, root: root)
      [true, "#{config.static_mapping_rules.size}件のルール"]
    rescue RegexpError, KeyError => e
      [false, e.message]
    end

    def parse!(command)
      OptionParser.new do |parser|
        parser.banner = "使い方: rspec-tia #{command} [オプション]"
        parser.on('--config PATH') { |v| @options[:config] = v }
        parser.on('--root PATH') { |v| @options[:root] = v }
        yield parser if block_given?
      end.parse!(@argv)
    end

    def root
      @options[:root] || Dir.pwd
    end

    def config
      @config ||= Configuration.load(@options[:config], root: root)
    end

    # 変更ファイルを外から渡せるようにしておく。
    # 過去のマージコミットを流して削減率と取りこぼしを事前に測る（オフライン検証）ために使う
    def select_context
      source = @options[:changed_files_from]
      return Ci.build(config).context if source.nil?

      lines = source == '-' ? $stdin.read : File.read(source)
      Context.new(
        changed_files: lines.split("\n").map(&:strip).reject(&:empty?),
        merge_request: true,
      )
    end

    def load_map
      path = config.map_path
      return Map.new unless File.exist?(path)

      Map.load(path)
    end

    def junit_report(dir)
      return nil if dir.nil? || !Dir.exist?(dir)

      JunitReport.load_dir(dir)
    end
  end
end
