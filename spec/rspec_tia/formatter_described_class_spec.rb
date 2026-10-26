require 'open3'
require 'rbconfig'
require 'json'

RSpec.describe 'described class dependency mapping' do
  def with_project_run(order: 'defined', enabled: true)
    Dir.mktmpdir do |root|
      Dir.mktmpdir do |external|
        File.write(File.join(external, 'outside.rb'), 'class OutsideTarget; end')
        files = {
          'lib/base.rb' => 'class BasePolicy; BASE = :base; end',
          'lib/included.rb' => 'module IncludedRules; INCLUDED = :included; end',
          'lib/prepended.rb' => 'module PrependedRules; PREPENDED = :prepended; end',
          'lib/policy.rb' => <<~SOURCE,
            class AccountPolicy < BasePolicy
              include IncludedRules
              prepend PrependedRules
              ROLE = :member
            end
          SOURCE
          'lib/other.rb' => 'module OtherTarget; VALUE = :other; end',
          'lib/nested.rb' => 'module Namespace; class Target; VALUE = :nested; end; end',
          'lib/runtime.rb' => <<~SOURCE,
            module RuntimeValue
              def self.call
                42
              end
            end
          SOURCE
          'spec/support/shared.rb' => <<~SOURCE,
            RSpec.shared_examples('policy') do
              it { expect(described_class::ROLE).to eq(:member) }
              it { expect(described_class::BASE).to eq(:base) }
              it { expect(described_class::INCLUDED).to eq(:included) }
              it { expect(described_class::PREPENDED).to eq(:prepended) }
            end
          SOURCE
          'spec/spec_helper.rb' => <<~SOURCE,
            Dir[File.expand_path('../lib/*.rb', __dir__)].sort_by { |p| p.end_with?('/policy.rb') ? 1 : 0 }.each { |p| require p }
            require #{File.join(external, 'outside.rb').inspect}
            require_relative 'support/shared'
          SOURCE
          'spec/a_spec.rb' => <<~SOURCE,
            require_relative 'spec_helper'
            RSpec.describe AccountPolicy do
              context('nested') { it_behaves_like 'policy' }
              describe OtherTarget do
                it { expect(described_class::VALUE).to eq(:other) }
              end
              it { expect(RuntimeValue.call).to eq(42) }
            end
            RSpec.describe OtherTarget do
              it { expect(described_class::VALUE).to eq(:other) }
            end
          SOURCE
          'spec/b_spec.rb' => <<~SOURCE,
            require_relative 'spec_helper'
            RSpec.describe AccountPolicy do
              context('nested') { include_examples 'policy' }
            end
          SOURCE
          'spec/other_spec.rb' => <<~SOURCE,
            require_relative 'spec_helper'
            RSpec.describe Namespace::Target do
              it { expect(described_class::VALUE).to eq(:nested) }
            end
            RSpec.describe('string description') { it { expect(1).to eq(1) } }
            RSpec.describe(Class.new) { it { expect(described_class).to be_a(Class) } }
            RSpec.describe(String) { it { expect(described_class).to eq(String) } }
            RSpec.describe(OutsideTarget) { it { expect(described_class).to eq(OutsideTarget) } }
          SOURCE
          '.rspec_tia.yml' => "described_class:\n  enabled: #{enabled}\n",
        }
        files.each do |path, body|
          full = File.join(root, path)
          FileUtils.mkdir_p(File.dirname(full))
          File.write(full, body)
        end
        lib = File.expand_path('../../lib', __dir__)
        env = { 'RSPEC_TIA_CONFIG' => nil, 'RSPEC_TIA_FRAGMENT_PATH' => File.join(root, 'map.json.gz'), 'RUBYOPT' => nil }
        command = [RbConfig.ruby, '-I', lib, '-rrspec_tia/boot', '-S', 'rspec', '--require', 'rspec_tia/formatter',
                   '--format', 'RspecTia::Formatter', '--order', order]
        output, status = Open3.capture2e(env, *command, chdir: root)
        expect(status.success?).to be(true), output
        yield root, RspecTia::Map.load(File.join(root, 'map.json.gz')), env
      end
    end
  end

  ['defined', 'rand:12', 'rand:97'].each do |order|
    it "attributes target and ancestor files to consumers and predicts each change (#{order})" do
      with_project_run(order: order) do |root, map|
        expected = {
          'lib/policy.rb' => %w(spec/a_spec.rb spec/b_spec.rb),
          'lib/base.rb' => %w(spec/a_spec.rb spec/b_spec.rb),
          'lib/included.rb' => %w(spec/a_spec.rb spec/b_spec.rb),
          'lib/prepended.rb' => %w(spec/a_spec.rb spec/b_spec.rb),
          'lib/other.rb' => %w(spec/a_spec.rb),
          'lib/nested.rb' => %w(spec/other_spec.rb),
          'lib/runtime.rb' => %w(spec/a_spec.rb),
        }
        predictor = RspecTia::Predictor.new(config: RspecTia::Configuration.new({}, root: root), map: map)
        expected.each do |source, specs|
          expect(map.specs_for(source)).to match_array(specs), source
          result = predictor.call(RspecTia::Context.new(changed_files: [source], merge_request: true))
          expect(result).not_to be_full_run
          expect(result.specs).to eq(specs)
        end
        expect(map.specs).to contain_exactly('spec/a_spec.rb', 'spec/b_spec.rb', 'spec/other_spec.rb')
        expect(map.sources).not_to include(a_string_matching(/outside/))
        expect(map.to_h.fetch('format_version')).to eq(1)
      end
    end
  end

  it 'can disable supplementation while preserving runtime coverage' do
    with_project_run(enabled: false) do |_root, map|
      %w(policy base included prepended other nested).each do |name|
        expect(map.specs_for("lib/#{name}.rb")).to be_empty
      end
      expect(map.specs_for('lib/runtime.rb')).to contain_exactly('spec/a_spec.rb')
    end
  end

  it 'selects assertion failures from a pre-change map for each target and ancestor' do
    with_project_run do |root, map, env|
      predictor = RspecTia::Predictor.new(config: RspecTia::Configuration.new({}, root: root), map: map)
      %w(policy base included prepended).each do |name|
        source = "lib/#{name}.rb"
        path = File.join(root, source)
        original = File.read(path)
        File.write(path, original.sub(/= :\w+/, '= :broken'))
        selected = predictor.call(RspecTia::Context.new(changed_files: [source], merge_request: true)).specs
        [%w(spec), selected].each do |specs|
          output, status = Open3.capture2e(env, RbConfig.ruby, '-S', 'rspec', '--format', 'json', *specs, chdir: root)
          report = JSON.parse(output)
          expect(status.exitstatus).to eq(1), output
          expect(report.fetch('summary').fetch('errors_outside_of_examples_count')).to eq(0)
          failures = report.fetch('examples').select { |example| example.fetch('status') == 'failed' }
          expect(failures.size).to eq(2)
          expect(failures.map { |example| example.fetch('exception').fetch('class') }.uniq)
            .to eq(['RSpec::Expectations::ExpectationNotMetError'])
          expect(failures.map { |example| example.fetch('id').split('[').first.delete_prefix('./') }.uniq.sort)
            .to eq(%w(spec/a_spec.rb spec/b_spec.rb))
        end
        File.write(path, original)
      end
    end
  end
end
