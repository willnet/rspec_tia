require 'open3'
require 'rbconfig'
require 'timeout'
require 'json'
require 'yaml'

# Every invocation runs a disposable application, never the checked-in fixture.
class RailsAppRunner
  REPOSITORY = File.expand_path('../..', __dir__)
  FIXTURE = File.join(REPOSITORY, 'test_apps/rails_app')
  TIMEOUT_SECONDS = 45
  Result = Struct.new(:status, :output, :report, :map, :diagnostic, keyword_init: true)

  def self.with_app(mode: :normal)
    Dir.mktmpdir('rspec-tia-rails-') do |directory|
      root = File.join(directory, 'app')
      FileUtils.cp_r(FIXTURE, root)
      yield new(root, mode: mode)
    end
  end

  attr_reader :root, :mode

  def initialize(root, mode:)
    @root = root
    @mode = mode
    @sequence = 0
    if mode == :without_ar
      path = File.join(root, '.rspec_tia.yml')
      data = YAML.safe_load_file(path)
      data['rails'] = { 'active_record' => false }
      File.write(path, YAML.dump(data))
    end
  end

  # This list comes from the fixture files, independently of the generated map.
  def all_specs
    Dir.glob('spec/**/*_spec.rb', base: root).sort
  end

  def expectations(name)
    YAML.safe_load_file(File.join(root, 'expectations', "#{name}.yml")).fetch('cases')
  end

  def validate_paths!(paths)
    Array(paths).each do |path|
      unless path.is_a?(String) && !File.absolute_path?(path) && !path.split('/').include?('..') &&
             File.file?(File.join(root, path))
        raise "Invalid fixture expectation path: #{path.inspect}"
      end
    end
  end

  def predict(map, changed_files)
    config = RspecTia::Configuration.load(root: root)
    RspecTia::Predictor.new(config: config, map: map).call(
      RspecTia::Context.new(changed_files: changed_files, merge_request: true),
    )
  end

  def mutate!(mutation)
    path = mutation.fetch('source')
    validate_paths!([path])
    absolute = File.join(root, path)
    source = File.read(absolute)
    before = mutation.fetch('before')
    after = mutation.fetch('after')
    raise "Mutation must change source: #{path}" if before.empty? || before == after
    raise "Expected exactly one mutation target in #{path}" unless source.scan(Regexp.new(Regexp.escape(before))).size == 1

    File.write(absolute, source.sub(before, after))
  end

  def run(mapping: true, order: 'defined', specs: nil)
    @sequence += 1
    artifacts = File.join(root, 'tmp', "run-#{@sequence}")
    FileUtils.mkdir_p(artifacts)
    report_path = File.join(artifacts, 'rspec.json')
    fragment_path = File.join(artifacts, 'map.json.gz')
    env = ENV.keys.grep(/\A(?:RSPEC_|SPEC_OPTS\z|CI_NODE_|TEST_ENV_NUMBER\z|PARALLEL_|RUBYOPT\z)/).to_h { |key| [key, nil] }
    env.merge!(
      'BUNDLE_GEMFILE' => File.join(REPOSITORY, 'Gemfile'),
      'DATABASE_URL' => nil,
      'RAILS_ENV' => 'test',
      'FIXTURE_EAGER_LOAD' => (mode != :normal).to_s,
      'RSPEC_TIA_CONFIG' => File.join(root, '.rspec_tia.yml'),
      'RSPEC_TIA_FRAGMENT_PATH' => mapping ? fragment_path : nil,
    )
    command = [RbConfig.ruby, '-I', File.join(REPOSITORY, 'lib'), '-rbundler/setup']
    command << '-rrspec_tia/boot' if mapping
    command += ['-S', 'rspec', '--options', File.join(root, '.rspec'), '--order', order,
                '--format', 'json', '--out', report_path]
    command += ['--require', 'rspec_tia/formatter', '--format', 'RspecTia::Formatter'] if mapping
    command += specs || ['spec']
    output, status = capture(env, command)
    diagnostic = "mode=#{mode} order=#{order} specs=#{(specs || all_specs).inspect}\n" \
                 "root=#{root}\ncommand=#{command.inspect}\nexit=#{status.exitstatus}\n#{output}"
    raise "Missing structured RSpec report\n#{diagnostic}" unless File.file?(report_path)

    report = JSON.parse(File.read(report_path))
    map = nil
    if mapping
      raise "Map generation failed\n#{diagnostic}\n#{report.inspect}" unless status.success?
      raise "Missing map fragment\n#{diagnostic}" unless File.file?(fragment_path)

      map = RspecTia::Map.merge_files([fragment_path])
      unless map.specs.to_a.sort == all_specs
        raise "Incomplete map: missing=#{all_specs - map.specs.to_a} extra=#{map.specs.to_a - all_specs}\n#{diagnostic}"
      end
    end
    Result.new(status: status, output: output, report: report, map: map, diagnostic: diagnostic)
  end

  # Reject boot errors, syntax errors, empty reports, and non-assertion failures.
  # Normalize shared examples to their consumer's top-level group, like Formatter.
  def assertion_failures!(result)
    examples = result.report.fetch('examples')
    failed = examples.select { |example| example.fetch('status') == 'failed' }
    valid = result.status.exitstatus == 1 && result.report.fetch('summary').fetch('errors_outside_of_examples_count').zero? &&
            !failed.empty? && failed.all? do |example|
              example.fetch('exception').fetch('class') == 'RSpec::Expectations::ExpectationNotMetError'
            end
    raise "Expected assertion failures, got:\n#{result.diagnostic}\n#{result.report.inspect}" unless valid

    failed.map do |example|
      # JSON's id identifies the runnable group; file_path may point at shared support.
      example.fetch('id').split('[').first.delete_prefix('./')
    end.uniq.sort
  end

  private

  def capture(env, command)
    output = +''
    status = nil
    Open3.popen2e(env, *command, chdir: root, pgroup: true) do |stdin, stdout, wait|
      stdin.close
      reader = Thread.new { stdout.read }
      begin
        Timeout.timeout(TIMEOUT_SECONDS) do
          status = wait.value
          output = reader.value
        end
      rescue Timeout::Error
        begin
          Process.kill('KILL', -wait.pid)
        rescue Errno::ESRCH
          # The process group may have exited just as the deadline expired.
        end
        wait.value
        output = reader.value
        raise "Rails fixture timed out after #{TIMEOUT_SECONDS}s (mode=#{mode}, root=#{root})\n#{command.inspect}\n#{output}"
      ensure
        output = reader.value
      end
    end
    [output, status]
  end
end
