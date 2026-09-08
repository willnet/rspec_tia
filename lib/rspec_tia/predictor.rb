require 'set'

module RspecTia
  # 変更ファイル一覧から、実行すべきspecファイルを決める。
  #
  # 3つの経路の和集合を取る。
  #   1. カバレッジマップの逆引き（主）
  #   2. 静的マッピング（新規ファイル・テンプレート・拾えなかったcode-lessクラスの補完）
  #   3. 変更されたspecファイルそのもの
  class Predictor
    Result = Struct.new(:full_run, :reason, :specs, :sources, keyword_init: true) do
      def full_run? = !!full_run
    end

    def initialize(config:, map:)
      @config = config
      @map = map
      @static_mapping = StaticMapping.new(config.static_mapping_rules, root: config.root)
      @fallback = Fallback.new(config: config, map: map)
    end

    def call(context)
      reason = @fallback.reason(context)
      return Result.new(full_run: true, reason: reason, specs: @config.all_specs, sources: context.changed_files) if reason

      specs = Set.new
      context.changed_files.each { |path| specs.merge(@map.specs_for(path)) }
      specs.merge(@static_mapping.call(context.changed_files))
      specs.merge(context.changed_files.select { |path| spec_file?(path) })

      Result.new(full_run: false, reason: nil, specs: existing(specs).sort, sources: context.changed_files)
    end

    private

    def spec_file?(path)
      File.fnmatch?(@config.spec_glob, path, Configuration::FNMATCH_FLAGS)
    end

    # 削除されたspecや、マップ生成後にリネームされたspecを実行対象から外す。
    # 存在しないパスを rspec に渡すとジョブ全体が落ちるため、ここで必ず絞る
    def existing(specs)
      specs.select { |path| File.exist?(File.join(@config.root, path)) }
    end
  end
end
