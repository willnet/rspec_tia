require 'open3'
require 'rbconfig'

RSpec.describe 'specロード後のRails依存補完' do
  def run_project(enabled, active_record: true, preload: false, describe_model: false)
    Dir.mktmpdir do |root|
      FileUtils.mkdir_p(File.join(root, 'app/models'))
      FileUtils.mkdir_p(File.join(root, 'spec'))
      File.write(File.join(root, '.rspec_tia.yml'), "rails:\n  enabled: #{enabled}\n  active_record: #{active_record}\n")
      File.write(File.join(root, 'app/models/user.rb'), "class User < ActiveRecord::Base\nend\n")
      File.write(File.join(root, 'spec/a_spec.rb'), <<~RUBY)
        require 'rails'
        require 'active_record'
        ActiveRecord::Base.establish_connection(adapter: 'sqlite3', database: ':memory:')
        ActiveRecord::Schema.define { create_table(:users) { |t| t.string :name } }
        require_relative '../app/models/user'
        User.create!(name: 'test')
        RSpec.describe(#{describe_model ? 'User' : "'real Rails model'"}) do
          it('loads a record') { expect(User.first.name).to eq('test') }
        end
      RUBY
      lib = File.expand_path('../../lib', __dir__)
      env = { 'RSPEC_TIA_CONFIG' => nil, 'RSPEC_TIA_FRAGMENT_PATH' => nil }
      command = [RbConfig.ruby, '-I', lib, '-rrspec_tia/boot']
      command += ['-rrails', '-ractive_record'] if preload
      output, status = Open3.capture2e(env, *command, '-S', 'rspec', '--require', 'rspec_tia/formatter',
                                     '--format', 'RspecTia::Formatter', chdir: root)
      expect(status.success?).to be(true), output
      map = RspecTia::Map.merge_files(Dir.glob(File.join(root, 'tmp/rspec_tia/fragments/*.json.gz')))
      yield map
    end
  end

  ['auto', true, false].each do |enabled|
    it "specがRailsをrequireする構成でrails.enabled=#{enabled}を尊重する" do
      run_project(enabled) do |map|
        expected = enabled == false ? [] : ['spec/a_spec.rb']
        expect(map.specs_for('app/models/user.rb').to_a).to eq(expected)
      end
    end
  end

  it 'ActiveRecord補完を無効化するとモデルを補完しない' do
    run_project('auto', active_record: false) do |map|
      expect(map.specs_for('app/models/user.rb')).to be_empty
    end
  end

  it 'Railsが先にロード済みでも補完する' do
    run_project('auto', preload: true) do |map|
      expect(map.specs_for('app/models/user.rb')).to contain_exactly('spec/a_spec.rb')
    end
  end

  it 'merges described class and ActiveRecord dependencies without duplicate edges' do
    run_project('auto', describe_model: true) do |map|
      expect(map.specs_for('app/models/user.rb')).to contain_exactly('spec/a_spec.rb')
      serialized = map.to_h
      index = serialized.fetch('sources').index('app/models/user.rb')
      expect(serialized.fetch('edges').fetch(index)).to eq([0])
    end
  end

  it 'Formatter生成時は購読せず、startが繰り返されても一度だけ購読する' do
    require 'rspec_tia/formatter'
    support = instance_double(RspecTia::RailsSupport, flush: [])
    config = RspecTia::Configuration.new({ 'rails' => { 'enabled' => true, 'action_view' => false } })
    allow(RspecTia).to receive(:config).and_return(config)
    allow(RspecTia::RailsSupport).to receive(:available?).and_return(true)
    allow(Coverage).to receive(:result)
    expect(RspecTia::RailsSupport).to receive(:new).once.and_return(support)
    expect(support).to receive(:subscribe).once.and_return(support)
    formatter = RspecTia::Formatter.new(nil)
    formatter.start(nil)
    formatter.start(nil)
  end
end
