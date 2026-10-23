require 'optparse'
require 'rspec_tia'
require 'rspec_tia/audit'
require 'rspec_tia/ci'
require 'rspec_tia/junit_report'
require 'rspec_tia/metrics'

module RspecTia
  class Cli
    USAGE = <<~TEXT.freeze
      Usage: rspec-tia <command> [options]

        select                Print selected specs (or full_run_token for a full run)
        map merge             Merge map fragments into a single map
        map fetch             Fetch and merge map fragments from CI
        audit                 Compare full-suite results with predictions to detect missed failures
        doctor                Check configuration and environment
        version               Print the version

      Common options:
        --config PATH         Configuration file (default: .rspec_tia.yml)
        --root PATH           Project root (default: current directory)
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
        warn "Unknown command: #{command}\n\n#{USAGE}"
        1
      end
    rescue Ci::Gitlab::AuthenticationError, Http::Error, Ci::Git::CommandError, Ci::UnknownAdapterError, Map::FormatError, Errno::ENOENT => e
      warn "[rspec_tia] #{e.message}"
      1
    end

    private

    def select
      parse!('select') do |parser|
        parser.on('--junit-dir DIR', 'JUnit XML directory for timing-based savings estimates') { |v| @options[:junit_dir] = v }
        parser.on('--metrics PATH', 'Metrics output path') { |v| @options[:metrics] = v }
        parser.on('--changed-files-from PATH', 'Read changed files from a file instead of CI (- for stdin)') do |v|
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
        warn "Usage: rspec-tia map [merge|fetch]"
        1
      end
    end

    def map_merge
      parse!('map merge') do |parser|
        parser.on('--fragments DIR', 'Map fragment directory') { |v| @options[:fragments] = v }
        parser.on('-o', '--output PATH', 'Merged map output path') { |v| @options[:output] = v }
      end

      dir = @options[:fragments] || config.map_fragment_dir
      fragments = Dir.glob(File.join(dir, '*.json*')).sort
      if fragments.empty?
        warn "[rspec_tia] No map fragments found: #{dir}"
        return 1
      end

      map = Map.merge_files(fragments)
      path = map.dump(@options[:output] || config.map_path)
      warn format('[rspec_tia] Merged %d fragments -> %s (%d specs / %d sources)',
                  fragments.size, path, map.specs.size, map.sources.size)
      0
    end

    def map_fetch
      parse!('map fetch') do |parser|
        parser.on('--dest DIR', 'Fragment download directory') { |v| @options[:dest] = v }
        parser.on('--[no-]merge', 'Merge after downloading (default: enabled)') { |v| @options[:merge] = v }
      end

      dest = @options[:dest] || config.map_fragment_dir
      fragments = Ci.build(config).fetch_map_fragments(dest)
      if fragments.empty?
        # Ensure even a reused workspace falls back to a full run when no map is available.
        File.delete(config.map_path) if File.exist?(config.map_path)
        warn '[rspec_tia] No map fragments available (selection will fall back to a full run)'
        return 0
      end

      warn "[rspec_tia] Fetched #{fragments.size} fragments -> #{dest}"
      return 0 if @options[:merge] == false

      @options[:fragments] = dest
      map_merge_from(fragments)
    end

    def map_merge_from(fragments)
      map = Map.merge_files(fragments)
      path = map.dump(@options[:output] || config.map_path)
      warn format('[rspec_tia] Created map -> %s (%d specs / %d sources)',
                  path, map.specs.size, map.sources.size)
      0
    end

    def audit
      parse!('audit') do |parser|
        parser.on('--junit DIR', 'JUnit XML directory from a full-suite run') { |v| @options[:junit] = v }
        parser.on('--predicted PATH', 'Predicted spec list (one path per line)') { |v| @options[:predicted] = v }
      end

      missing = %i(junit predicted).reject { |key| @options[key] }
      unless missing.empty?
        warn "[rspec_tia] Required options: --#{missing.join(' and --')}"
        return 1
      end

      predicted = File.readlines(@options[:predicted], chomp: true).reject(&:empty?)
      result = Audit.new(
        junit_report: JunitReport.load_dir(@options[:junit]),
        predicted_specs: predicted,
        full_run: predicted == [config.full_run_token],
      ).call
      warn result.summary
      result.ok? ? 0 : 1
    end

    def doctor
      parse!('doctor')
      checks = [
        ['Configuration', config_status],
        ['Spec discovery', spec_status],
        ['Coverage map', map_status],
        ['CI adapter', adapter_status],
        ['Static mappings', static_mapping_status],
      ]
      ok = checks.all? { |_, (result, _)| result }
      checks.each { |name, (result, detail)| puts format('%s %-16s %s', result ? 'ok  ' : 'NG  ', name, detail) }
      ok ? 0 : 1
    end

    def config_status
      path = @options[:config] || File.join(root, Configuration::DEFAULT_PATH)
      File.exist?(path) ? [true, path] : [false, "#{path} not found (using defaults)"]
    end

    def spec_status
      count = config.all_specs.size
      [count.positive?, "#{config.spec_glob} -> #{count} specs"]
    end

    def map_status
      return [false, "#{config.map_path} does not exist"] unless File.exist?(config.map_path)

      map = Map.load(config.map_path)
      stale = map.stale?(max_age_days: config.map_max_age_days)
      detail = "#{map.specs.size} specs / #{map.sources.size} sources / generated #{map.generated_at&.utc&.iso8601 || 'unknown'}"
      [!stale, stale ? "#{detail} (stale)" : detail]
    end

    def adapter_status
      adapter = Ci.build(config)
      [true, "#{adapter.class.name}（MR: #{adapter.merge_request?}）"]
    rescue Ci::UnknownAdapterError => e
      [false, e.message]
    end

    def static_mapping_status
      StaticMapping.new(config.static_mapping_rules, root: root)
      [true, "#{config.static_mapping_rules.size} rules"]
    rescue RegexpError, KeyError => e
      [false, e.message]
    end

    def parse!(command)
      OptionParser.new do |parser|
        parser.banner = "Usage: rspec-tia #{command} [options]"
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

    # Allow changed files to be supplied externally.
    # This supports offline evaluation of savings and missed failures using historical merge commits.
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
