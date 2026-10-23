require 'fileutils'
require 'json'

module RspecTia
  # Record how much work each prediction eliminates.
  #
  # Always record savings and full-run reasons when using selective execution in CI.
  # When JUnit XML is available, also estimate savings using measured durations.
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
        "[rspec_tia] Full run: #{data['reason']} (#{data['total_spec_count']} specs)"
      else
        format(
          '[rspec_tia] Selected specs: %d / %d (%.1f%%)%s',
          data['predicted_spec_count'],
          data['total_spec_count'],
          (data['spec_ratio'] || 0) * 100,
          data['time_ratio'] ? format(' / Estimated runtime %.1f%%', data['time_ratio'] * 100) : '',
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
