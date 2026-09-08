module RspecTia
  # 「予測せず全specを実行する」条件の判定。
  #
  # カバレッジで検出できない変更（依存gem・CI定義・実行環境）と、
  # 予測の信頼性が落ちる状況（マップが古い・変更が大きすぎる）を列挙する。
  # 判定結果は理由の文字列で返し、CIのログとメトリクスに残す。
  class Fallback
    SAMPLE_SIZE = 5

    def initialize(config:, map:)
      @config = config
      @map = map
    end

    def reason(context)
      not_merge_request(context) ||
        missing_map ||
        stale_map ||
        matched_label(context) ||
        matched_commit_message(context) ||
        too_many_changes(context) ||
        matched_full_run_path(context)
    end

    private

    def not_merge_request(context)
      return nil if context.merge_request?

      'MRのパイプラインではないため'
    end

    def missing_map
      return nil unless @map.nil? || @map.empty?

      'カバレッジマップが取得できていないため'
    end

    def stale_map
      return nil unless @map.stale?(max_age_days: @config.map_max_age_days)

      generated = @map.generated_at ? @map.generated_at.utc.iso8601 : '不明'
      "カバレッジマップが古いため（生成: #{generated} / 許容: #{@config.map_max_age_days}日）"
    end

    def matched_label(context)
      hit = @config.full_run_labels & context.labels
      return nil if hit.empty?

      "全実行ラベルが付いているため: #{hit.join(', ')}"
    end

    def matched_commit_message(context)
      message = context.commit_message.to_s
      hit = @config.full_run_commit_message_tokens.select { |token| message.include?(token) }
      return nil if hit.empty?

      "コミットメッセージに全実行の指定があるため: #{hit.join(', ')}"
    end

    def too_many_changes(context)
      limit = @config.max_changed_files
      return nil if limit.nil? || context.changed_files.size <= limit

      "変更ファイル数が多いため（#{context.changed_files.size}件 > #{limit}件）"
    end

    def matched_full_run_path(context)
      hit = context.changed_files.select { |path| @config.full_run_path?(path) }
      return nil if hit.empty?

      sample = hit.first(SAMPLE_SIZE).join(', ')
      suffix = hit.size > SAMPLE_SIZE ? " ほか#{hit.size - SAMPLE_SIZE}件" : ''
      "全実行対象のファイルが変更されたため: #{sample}#{suffix}"
    end
  end
end
