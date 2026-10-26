require 'coverage'
require 'rspec/core'
require 'rspec/core/formatters'
require 'set'
require 'rspec_tia'
require 'rspec_tia/rails_support'
require 'rspec_tia/described_class_support'

module RspecTia
  # RSpec formatter that records coverage dependencies per spec file as map fragments.
  #
  #   RUBYOPT="-rrspec_tia/boot" bundle exec rspec \
  #     --require rspec_tia/formatter --format RspecTia::Formatter
  #
  # How it works:
  #   - Clear coverage once at suite start. With eager_load enabled, boot executes
  #     every class definition; retaining those hits would link every spec to every file.
  #   - Call Coverage.result(clear: true) whenever the spec file changes.
  #     Each result then contains only files touched by that spec, avoiding cumulative diffs.
  #
  # Collect coverage per spec file because per-example collection increases calls by two orders of magnitude.
  # Observed collection cost per spec file was 25–31 ms.
  class Formatter
    RSpec::Core::Formatters.register self, :start, :example_group_started, :example_group_finished, :example_started, :stop

    def initialize(_output)
      @config = RspecTia.config
      @root = @config.root.end_with?('/') ? @config.root : "#{@config.root}/"
      @map = Map.new(generated_at: Time.now, commit_sha: RspecTia.commit_sha)
      @current_spec = nil
      @rails_support = nil
      @described_class_support = DescribedClassSupport.new(root: @root) if @config.described_class_enabled?
    end

    def start(_notification)
      @rails_support ||= build_rails_support
      # Discard lines executed during boot and spec loading.
      Coverage.result(stop: false, clear: true)
      @rails_support&.flush
    end

    # Group start arrives before before(:context); group finish arrives after after(:context).
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
      if @described_class_support
        @map.add(@current_spec, @described_class_support.files_for(notification.example.example_group.described_class))
      end
    end

    def stop(notification)
      flush
      @map.specs.each { |spec| @map.add(spec, (@suite_sources || []).to_a) }
      if notification.failed_examples.any? || RSpec.world.non_example_failure
        # Maps with unexecuted paths due to failed hooks or fail-fast must not pass freshness checks.
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
      # Use the runnable top-level group’s spec, rather than the shared examples definition.
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
        # Attribute before/after(:suite) dependencies to every spec, not just the first or last.
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

    # Write a separate file for each parallel_tests process and CI node.
    # Reusing a filename would let processes overwrite dependencies recorded by other processes.
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
