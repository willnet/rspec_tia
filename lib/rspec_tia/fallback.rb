module RspecTia
  # Determine when to run every spec instead of predicting.
  #
  # Cover changes invisible to coverage, such as gems, CI definitions, and the execution environment,
  # as well as situations that reduce confidence, such as stale maps or large changes.
  # Return the reason as text for CI logs and metrics.
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

      'Not a merge request pipeline'
    end

    def missing_map
      return nil unless @map.nil? || @map.empty?

      'No coverage map available'
    end

    def stale_map
      return nil unless @map.stale?(max_age_days: @config.map_max_age_days)

      generated = @map.generated_at ? @map.generated_at.utc.iso8601 : 'unknown'
      "Coverage map is stale (generated: #{generated} / maximum age: #{@config.map_max_age_days} days)"
    end

    def matched_label(context)
      hit = @config.full_run_labels & context.labels
      return nil if hit.empty?

      "Full-run label matched: #{hit.join(', ')}"
    end

    def matched_commit_message(context)
      message = context.commit_message.to_s
      hit = @config.full_run_commit_message_tokens.select { |token| message.include?(token) }
      return nil if hit.empty?

      "Full-run token found in commit message: #{hit.join(', ')}"
    end

    def too_many_changes(context)
      limit = @config.max_changed_files
      return nil if limit.nil? || context.changed_files.size <= limit

      "Too many changed files (#{context.changed_files.size} > #{limit})"
    end

    def matched_full_run_path(context)
      hit = context.changed_files.select { |path| @config.full_run_path?(path) }
      return nil if hit.empty?

      sample = hit.first(SAMPLE_SIZE).join(', ')
      suffix = hit.size > SAMPLE_SIZE ? " and #{hit.size - SAMPLE_SIZE} more" : ''
      "Full-run path changed: #{sample}#{suffix}"
    end
  end
end
