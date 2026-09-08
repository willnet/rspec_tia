require 'fileutils'
require 'json'

module RspecTia
  # 予測が何をどれだけ削ったかを記録する。
  #
  # 予測実行を本番で使う以上、削減率と、全実行に倒れた理由は毎回残しておく。
  # junit.xml があれば、件数ではなく実測時間で重み付けした削減率も出す。
  class Metrics
    def initialize(config:, result:, junit_report: nil)
      @config = config
      @result = result
      @junit_report = junit_report
    end

    def to_h
      all_specs = @config.all_specs
      base = {
        'full_run' => @result.full_run?,
        'reason' => @result.reason,
        'changed_file_count' => @result.sources.size,
        'predicted_spec_count' => @result.specs.size,
        'total_spec_count' => all_specs.size,
        'spec_ratio' => ratio(@result.specs.size, all_specs.size),
      }
      base.merge(time_metrics(all_specs))
    end

    def write(path = @config.metrics_path)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, JSON.pretty_generate(to_h))
      path
    end

    def summary
      data = to_h
      if data['full_run']
        "[rspec_tia] 全実行: #{data['reason']}（#{data['total_spec_count']}件）"
      else
        format(
          '[rspec_tia] 予測実行: %d / %d 件 (%.1f%%)%s',
          data['predicted_spec_count'],
          data['total_spec_count'],
          (data['spec_ratio'] || 0) * 100,
          data['time_ratio'] ? format(' / 推定実行時間 %.1f%%', data['time_ratio'] * 100) : '',
        )
      end
    end

    private

    def time_metrics(all_specs)
      return {} if @junit_report.nil? || @junit_report.empty?

      durations = @junit_report.durations
      predicted = @result.specs.sum { |spec| durations[spec] }
      total = all_specs.sum { |spec| durations[spec] }

      {
        'estimated_seconds' => predicted.round(1),
        'total_estimated_seconds' => total.round(1),
        'time_ratio' => ratio(predicted, total),
      }
    end

    def ratio(numerator, denominator)
      return nil if denominator.nil? || denominator.zero?

      (numerator.to_f / denominator).round(4)
    end
  end
end
