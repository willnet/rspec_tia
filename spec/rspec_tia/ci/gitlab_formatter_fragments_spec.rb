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
end
