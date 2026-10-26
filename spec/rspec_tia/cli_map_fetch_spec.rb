require 'rspec_tia/cli'

RSpec.describe 'map fetch後の予測' do
  def write_map(path, time, source)
    map = RspecTia::Map.new(generated_at: time)
    map.add('spec/a_spec.rb', [source])
    map.dump(path)
  end

  def select(root)
    RspecTia::Cli.start(['select', '--root', root, '--changed-files-from', File.join(root, 'changed.txt')])
  end

  around do |example|
    with_project(['spec/a_spec.rb']) do |root|
      @root = root
      # Verify fetch and select share the same configuration even with a custom map_path.
      File.write(File.join(root, '.rspec_tia.yml'), "map:\n  path: cache/current.json.gz\n")
      File.write(File.join(root, 'changed.txt'), "lib/new.rb\n")
      @config = RspecTia::Configuration.load(root: root)
      example.run
    end
  end

  before do
    @adapter = instance_double(RspecTia::Ci::Base)
    allow(RspecTia::Ci).to receive(:build).and_return(@adapter)
    allow_any_instance_of(RspecTia::Cli).to receive(:warn)
  end

  { 'なし' => nil, '古い' => -10 * 86_400, '新鮮' => 0 }.each do |name, age|
    [[], ['--no-merge']].each do |options|
      it "取得ゼロ件で既存マップが#{name}なら後続selectは全実行になる #{options.join(' ')}" do
        write_map(@config.map_path, Time.now + age, 'lib/old.rb') if age
        allow(@adapter).to receive(:fetch_map_fragments).and_return([])

        expect(RspecTia::Cli.start(['map', 'fetch', '--root', @root, *options])).to eq(0)
        expect(File.exist?(@config.map_path)).to be(false)
        expect { expect(select(@root)).to eq(0) }.to output("spec\n").to_stdout
      end
    end
  end

  it '取得した断片で既存マップを置き換え、後続selectで新しい依存を使う' do
    write_map(@config.map_path, Time.now, 'lib/old.rb')
    fragment = File.join(@root, 'download/new.json.gz')
    write_map(fragment, Time.now, 'lib/new.rb')
    allow(@adapter).to receive(:fetch_map_fragments).and_return([fragment])

    expect(RspecTia::Cli.start(['map', 'fetch', '--root', @root])).to eq(0)
    map = RspecTia::Map.load(@config.map_path)
    expect(map.sources).to contain_exactly('lib/new.rb')
    expect { expect(select(@root)).to eq(0) }.to output("spec/a_spec.rb\n").to_stdout
  end

  it '取得に対応しないアダプタでは既存マップを維持して非ゼロ終了する' do
    write_map(@config.map_path, Time.now, 'lib/old.rb')
    original = File.binread(@config.map_path)
    allow(RspecTia::Ci).to receive(:build).and_return(RspecTia::Ci::Git.new(@config))
    diagnostic = nil
    allow_any_instance_of(RspecTia::Cli).to receive(:warn) { |_cli, message| diagnostic = message }

    expect(RspecTia::Cli.start(['map', 'fetch', '--root', @root])).to eq(1)
    expect(diagnostic).to include('does not support map fetching')
    expect(File.binread(@config.map_path)).to eq(original)
  end

  it '壊れた既存マップではselectが何も出力せず非ゼロ終了する' do
    FileUtils.mkdir_p(File.dirname(@config.map_path))
    File.binwrite(@config.map_path, "\x1f\x8b\x08\x00broken".b)
    diagnostic = nil
    allow_any_instance_of(RspecTia::Cli).to receive(:warn) { |_cli, message| diagnostic = message }

    expect { expect(select(@root)).to eq(1) }.to output('').to_stdout
    expect(diagnostic).to include('Invalid map file', @config.map_path)
  end

  it '取得成功時の--no-mergeは既存マップを変更しない' do
    write_map(@config.map_path, Time.now, 'lib/old.rb')
    original = File.binread(@config.map_path)
    fragment = File.join(@root, 'download/new.json.gz')
    write_map(fragment, Time.now, 'lib/new.rb')
    allow(@adapter).to receive(:fetch_map_fragments).and_return([fragment])

    expect(RspecTia::Cli.start(['map', 'fetch', '--root', @root, '--no-merge'])).to eq(0)
    expect(File.binread(@config.map_path)).to eq(original)
  end
end
