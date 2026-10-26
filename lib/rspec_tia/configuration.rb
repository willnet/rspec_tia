require 'yaml'

module RspecTia
  # Load .rspec_tia.yml and apply defaults.
  #
  # Match path patterns with File.fnmatch?(FNM_PATHNAME | FNM_EXTGLOB).
  # Use patterns such as config/**/*, as in GitLab CI rules:changes.
  # The pattern config/** does not match nested paths.
  class Configuration
    DEFAULT_PATH = '.rspec_tia.yml'.freeze
    FNMATCH_FLAGS = File::FNM_PATHNAME | File::FNM_EXTGLOB

    DEFAULTS = {
      'spec_glob' => 'spec/**/*_spec.rb',
      # The single line emitted by select for a full run; use a value accepted by RSpec or a splitting script.
      'full_run_token' => 'spec',
      'map' => {
        'fragment_dir' => 'tmp/rspec_tia/fragments',
        'path' => 'tmp/rspec_tia/map.json.gz',
        'max_age_days' => 3,
      },
      'full_run' => {
        'paths' => [],
        'max_changed_files' => 300,
        'labels' => [],
        'commit_message_tokens' => [],
      },
      'static_mapping' => [],
      'described_class' => { 'enabled' => true },
      'rails' => {
        'enabled' => 'auto',
        'active_record' => true,
      },
      'ci' => {
        'adapter' => 'auto',
        'gitlab' => {
          'map_ref' => 'master',
          'map_pipeline_source' => 'schedule',
          'map_job_name' => nil,
          'map_artifact_glob' => 'tmp/rspec_tia/fragments',
        },
      },
      'metrics_path' => 'tmp/rspec_tia/metrics.json',
    }.freeze

    class << self
      def load(path = nil, root: Dir.pwd)
        root = File.expand_path(root)
        path ||= File.join(root, DEFAULT_PATH)
        raw = File.exist?(path) ? (YAML.safe_load_file(path) || {}) : {}
        new(raw, root: root)
      end
    end

    attr_reader :root

    def initialize(raw, root: Dir.pwd)
      @root = File.expand_path(root)
      @data = deep_merge(DEFAULTS, raw || {})
    end

    def spec_glob = @data.fetch('spec_glob')
    def full_run_token = @data.fetch('full_run_token')
    def metrics_path = absolute(@data.fetch('metrics_path'))

    def map_fragment_dir = absolute(dig('map', 'fragment_dir'))
    def map_path = absolute(dig('map', 'path'))
    def map_max_age_days = dig('map', 'max_age_days')

    def full_run_paths = dig('full_run', 'paths')
    def max_changed_files = dig('full_run', 'max_changed_files')
    def full_run_labels = dig('full_run', 'labels')
    def full_run_commit_message_tokens = dig('full_run', 'commit_message_tokens')

    def static_mapping_rules = @data.fetch('static_mapping')
    def described_class_enabled? = dig('described_class', 'enabled')

    def ci_adapter = dig('ci', 'adapter')
    def gitlab_options = dig('ci', 'gitlab')

    def active_record_enabled? = dig('rails', 'active_record')

    # In auto mode, enable support when Rails is loaded.
    # Enable eager-load handling and model dependency supplementation by default to avoid silently losing accuracy.
    def rails_enabled?
      value = dig('rails', 'enabled')
      return !!value unless value == 'auto'

      defined?(::Rails) ? true : false
    end

    def all_specs
      Dir.chdir(@root) { Dir.glob(spec_glob).sort }
    end

    def full_run_path?(path)
      full_run_paths.any? { |pattern| File.fnmatch?(pattern, path, FNMATCH_FLAGS) }
    end

    def absolute(path)
      return path if path.nil?

      File.absolute_path?(path) ? path : File.join(@root, path)
    end

    private

    def dig(*keys) = @data.dig(*keys)

    def deep_merge(base, override)
      base.merge(override) do |_key, old, new|
        old.is_a?(Hash) && new.is_a?(Hash) ? deep_merge(old, new) : new
      end
    end
  end
end
