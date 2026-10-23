require 'open3'
require 'rbconfig'
require 'zip'

RSpec.describe 'Formatterの断片をGitLabから取得する' do
  cases = [
    ['3', '', nil], ['3', '2', nil], [nil, nil, nil], [nil, '2', nil],
    ['3', '', 'custom/output.json.gz'],
  ]

  cases.each do |node, process, custom_path|
    it "生成→artifact取得→マージが成功する（node=#{node.inspect}, process=#{process.inspect}, custom=#{custom_path.inspect}）" do
      Dir.mktmpdir do |root|
        FileUtils.mkdir_p(File.join(root, 'lib'))
        FileUtils.mkdir_p(File.join(root, 'spec'))
        File.write(File.join(root, 'lib/value.rb'), "module Value\n  def self.call\n    42\n  end\nend\n")
        File.write(File.join(root, 'spec/a_spec.rb'), <<~RUBY)
          require_relative '../lib/value'
          RSpec.describe('value') { it('works') { expect(Value.call).to eq(42) } }
        RUBY
        lib = File.expand_path('../../../lib', __dir__)
        env = { 'CI_NODE_INDEX' => node, 'TEST_ENV_NUMBER' => process, 'RSPEC_TIA_CONFIG' => nil,
                'RSPEC_TIA_FRAGMENT_PATH' => custom_path && File.join(root, custom_path) }
        output, status = Open3.capture2e(env, RbConfig.ruby, '-I', lib, '-rrspec_tia/boot', '-S', 'rspec',
                                       '--require', 'rspec_tia/formatter', '--format', 'RspecTia::Formatter', chdir: root)
        expect(status.success?).to be(true), output
        paths = Dir.glob(File.join(root, '**/*.json.gz'))
        expect(paths.size).to eq(1)
        archive = Zip::OutputStream.write_buffer do |zip|
          paths.each do |path|
            zip.put_next_entry(path.delete_prefix("#{root}/"))
            zip.write(File.binread(path))
          end
        end.string
        config = RspecTia::Configuration.new({ 'ci' => { 'gitlab' => {
          'map_artifact_glob' => custom_path || 'tmp/rspec_tia/fragments' } } }, root: root)
        adapter = RspecTia::Ci::Gitlab.new(config)
        http = instance_double(RspecTia::Http)
        allow(adapter).to receive(:http).and_return(http)
        allow(http).to receive(:get).with('/projects/42/jobs/1/artifacts').and_return(archive)
        original = ENV['CI_PROJECT_ID']
        begin
          ENV['CI_PROJECT_ID'] = '42'
          dest = File.join(root, 'download')
          FileUtils.mkdir_p(dest)
          saved = adapter.send(:download_fragments, { 'id' => 1, 'name' => 'map 3/3' }, dest)
          map = RspecTia::Map.merge_files(saved)
          expect(map.specs_for('lib/value.rb')).to contain_exactly('spec/a_spec.rb')
        ensure
          ENV['CI_PROJECT_ID'] = original
        end
      end
    end
  end
  ['tmp/rspec_tia/fragments', 'tmp/rspec_tia/fragments/**/*',
   'tmp/rspec_tia/fragments/{map-3.json.gz,map-4.json}'].each do |pattern|
    it "#{pattern}からJSON断片だけを取得してマージする" do
      Dir.mktmpdir do |root|
        fragment = RspecTia::Map.new.add('spec/a_spec.rb', ['lib/a.rb']).to_h
        archive = Zip::OutputStream.write_buffer do |zip|
          %w(map-3.json.gz map-4.json map-3.json.gz.sha256 map-3.json.log report.xml).each do |name|
            zip.put_next_entry("tmp/rspec_tia/fragments/#{name}")
            zip.write(name.end_with?('.json', '.json.gz') ? JSON.generate(fragment) : 'sidecar')
          end
        end.string
        config = RspecTia::Configuration.new({ 'ci' => { 'gitlab' => { 'map_artifact_glob' => pattern } } }, root: root)
        adapter = RspecTia::Ci::Gitlab.new(config)
        allow(adapter).to receive(:project_id).and_return('42')
        http = instance_double(RspecTia::Http)
        allow(adapter).to receive(:http).and_return(http)
        expect(http).to receive(:get).with('/projects/42/jobs/1/artifacts').and_return(archive)
        saved = adapter.send(:download_fragments, { 'id' => 1, 'name' => 'map' }, root)
        expect(saved.map { |path| File.basename(path) }).to eq(%w(job_1_0_map-3.json.gz job_1_1_map-4.json))
        expect(RspecTia::Map.merge_files(saved).specs_for('lib/a.rb')).to contain_exactly('spec/a_spec.rb')
      end
    end
  end

end
