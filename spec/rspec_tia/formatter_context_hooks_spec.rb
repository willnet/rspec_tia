require 'open3'
require 'rbconfig'

RSpec.describe 'context hookの依存帰属' do
  def project_run(order, failure: nil)
    Dir.mktmpdir do |root|
      files = {}
      %w(a_before a_after nested second b_before b_after suite_before suite_after).each do |name|
        constant = name.split('_').map(&:capitalize).join
        files["lib/#{name}.rb"] = "module #{constant}\n  def self.call\n    42\n  end\nend\n"
      end
      files['spec/a_spec.rb'] = <<~RUBY
        Dir[File.expand_path('../lib/*.rb', __dir__)].each { |path| require path }
        RSpec.configure do |c|
          c.before(:suite) { SuiteBefore.call }
          c.after(:suite) { SuiteAfter.call }
        end
        RSpec.describe('A') do
          before(:context) { ABefore.call; #{failure == :before ? "raise 'hook failed'" : ''} }
          after(:context) { AAfter.call; #{failure == :after ? "raise 'hook failed'" : ''} }
          it('ordinary') { expect(42).to eq(42) }
          context('nested') do
            before(:all) { Nested.call }
            it('nested example') { expect(42).to eq(42) }
          end
        end
        RSpec.describe('Another A group') do
          before(:all) { Second.call }
          it('second group') { expect(42).to eq(42) }
        end
      RUBY
      files['spec/b_spec.rb'] = <<~RUBY
        Dir[File.expand_path('../lib/*.rb', __dir__)].each { |path| require path }
        RSpec.describe('B') do
          before(:context) { BBefore.call }
          after(:context) { BAfter.call }
          it('example') { expect(42).to eq(42) }
        end
      RUBY
      files.each do |path, body|
        full = File.join(root, path)
        FileUtils.mkdir_p(File.dirname(full))
        File.write(full, body)
      end
      lib = File.expand_path('../../lib', __dir__)
      env = { 'RSPEC_TIA_CONFIG' => nil, 'RSPEC_TIA_FRAGMENT_PATH' => nil }
      output, status = Open3.capture2e(env, RbConfig.ruby, '-I', lib, '-rrspec_tia/boot', '-S', 'rspec',
                                     '--require', 'rspec_tia/formatter', '--format', 'RspecTia::Formatter',
                                     '--order', order, chdir: root)
      map = RspecTia::Map.merge_files(Dir.glob(File.join(root, 'tmp/rspec_tia/fragments/*.json.gz')))
      yield map, status, output
    end
  end

  ['defined', 'rand:12', 'rand:97'].each do |order|
    it "before/after・ネスト・複数group・suiteの帰属を保つ（#{order}）" do
      project_run(order) do |map, status, output|
        expect(status.success?).to be(true), output
        %w(a_before a_after nested second).each do |name|
          expect(map.specs_for("lib/#{name}.rb")).to contain_exactly('spec/a_spec.rb')
        end
        %w(b_before b_after).each do |name|
          expect(map.specs_for("lib/#{name}.rb")).to contain_exactly('spec/b_spec.rb')
        end
        %w(suite_before suite_after).each do |name|
          expect(map.specs_for("lib/#{name}.rb")).to contain_exactly('spec/a_spec.rb', 'spec/b_spec.rb')
        end
        expect(map).not_to be_stale(max_age_days: 3)
      end
    end
  end

  [:before, :after].each do |hook|
    it "#{hook}(:context)で失敗しても不完全なマップを新鮮と判定しない" do
      project_run('defined', failure: hook) do |map, status, output|
        expect(status.success?).to be(false), output
        expect(output).to include('saving the generated map as stale')
        expect(map).to be_stale(max_age_days: 3)
        expect(map.specs_for('lib/a_before.rb')).to include('spec/a_spec.rb')
        expect(map.specs_for('lib/a_after.rb')).to include('spec/a_spec.rb')
      end
    end
  end
end
