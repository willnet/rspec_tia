require 'rspec_tia/cli'
require 'zip'

RSpec.describe 'GitLabマップ取得の完全性' do
  around do |example|
    original = ENV['CI_PROJECT_ID']
    ENV['CI_PROJECT_ID'] = '42'
    with_project(['spec/old_spec.rb', 'spec/new_spec.rb']) do |root|
      @root = root
      File.write(File.join(root, '.rspec_tia.yml'), "ci:\n  adapter: gitlab\n  gitlab:\n    map_job_name: map\n")
      @config = RspecTia::Configuration.load(root: root)
      RspecTia::Map.new(generated_at: Time.now).add('spec/old_spec.rb', ['lib/old.rb']).dump(@config.map_path)
      @original_map = File.binread(@config.map_path)
      example.run
    end
  ensure
    ENV['CI_PROJECT_ID'] = original
  end

  before do
    @pipeline = { 'id' => 100, 'created_at' => Time.now.iso8601, 'sha' => 'pipeline-sha' }
    @http = instance_double(RspecTia::Http)
    @adapter = RspecTia::Ci::Gitlab.new(@config)
    allow(@adapter).to receive(:http).and_return(@http)
    allow(RspecTia::Ci).to receive(:build).and_return(@adapter)
    allow(@http).to receive(:get_json).with(a_string_including('/pipelines?')).and_return([@pipeline])
    allow_any_instance_of(RspecTia::Cli).to receive(:warn)
  end

  def map_json(index = 1, sha: 'pipeline-sha', time: Time.now)
    map = RspecTia::Map.new(generated_at: time, commit_sha: sha)
    map.add("spec/#{index}_spec.rb", ["lib/#{index}.rb"])
    JSON.generate(map.to_h)
  end

  def archive(entries)
    Zip::OutputStream.write_buffer do |zip|
      entries.each do |name, body|
        zip.put_next_entry("tmp/rspec_tia/fragments/#{name}")
        zip.write(body)
      end
    end.string
  end

  def jobs(values = [{ 'id' => 1, 'name' => 'map', 'status' => 'success' }])
    expect(@http).to receive(:get_json)
      .with(a_string_including('/pipelines/100/jobs?include_retried=false')).and_return(values)
  end

  def fetch
    RspecTia::Cli.start(['map', 'fetch', '--root', @root])
  end

  def expect_failure
    expect(fetch).to eq(1)
    expect(File.binread(@config.map_path)).to eq(@original_map)
    expect(Dir.glob(File.join(@config.map_fragment_dir, '**', '*')).select { |path| File.file?(path) }).to be_empty
  end

  it '9プロセス以上の全断片を検証してまとめる' do
    jobs
    entries = (1..10).to_h { |index| ["map-1-#{index}.json.gz", map_json(index)] }
    allow(@http).to receive(:get).with('/projects/42/jobs/1/artifacts').and_return(archive(entries))
    expect(fetch).to eq(0)
    map = RspecTia::Map.load(@config.map_path)
    expect(map.specs.size).to eq(10)
    expect(map.specs_for('lib/10.rb')).to contain_exactly('spec/10_spec.rb')
    expect(map.sources).not_to include('lib/old.rb')
  end

  it 'ノードの全artifact取得に成功した場合だけマップを置き換える' do
    jobs([{ 'id' => 1, 'name' => 'map 1/2', 'status' => 'success' },
          { 'id' => 2, 'name' => 'map 2/2', 'status' => 'success' }])
    [1, 2].each do |index|
      allow(@http).to receive(:get).with("/projects/42/jobs/#{index}/artifacts")
        .and_return(archive("map-#{index}.json.gz" => map_json(index)))
    end
    expect(fetch).to eq(0)
    expect(RspecTia::Map.load(@config.map_path).specs).to contain_exactly('spec/1_spec.rb', 'spec/2_spec.rb')
  end

  [RspecTia::Http::Error, RspecTia::Http::NotFound].each do |error|
    it "1ノードの#{error}を列挙終了として扱わず既存マップを維持する" do
      jobs([{ 'id' => 1, 'name' => 'map 1/2', 'status' => 'success' },
            { 'id' => 2, 'name' => 'map 2/2', 'status' => 'success' }])
      allow(@http).to receive(:get).with('/projects/42/jobs/1/artifacts')
        .and_return(archive('map-1.json.gz' => map_json(1)))
      allow(@http).to receive(:get).with('/projects/42/jobs/2/artifacts').and_raise(error, 'timeout or missing')
      expect_failure
    end
  end

  [
    [],
    [{ 'id' => 1, 'name' => 'other-map', 'status' => 'success' }],
    [{ 'id' => 1, 'name' => 'map 1/2', 'status' => 'success' }],
    [{ 'id' => 1, 'name' => 'map 1/2', 'status' => 'success' }, { 'id' => 2, 'name' => 'map 2/2', 'status' => 'failed' }],
    [{ 'id' => 1, 'name' => 'map 1/2', 'status' => 'success' }, { 'id' => 2, 'name' => 'map 1/2', 'status' => 'success' }],
    [{ 'id' => 1, 'name' => 'map ruby-3.3', 'status' => 'success' }],
  ].each_with_index do |values, index|
    it "ジョブ不一致・ノード欠落・失敗・重複を検出する（#{index}）" do
      jobs(values)
      expect(@http).not_to receive(:get)
      expect_failure
    end
  end

  [
    -> { {} },
    -> { { 'map.json.gz' => 'broken JSON' } },
    -> { { 'map.json.gz' => JSON.generate(RspecTia::Map.new(generated_at: Time.now).to_h) } },
    -> { { 'map.json.gz' => map_json(1, sha: 'other-commit') } },
    -> { { 'map.json.gz' => map_json(1, time: Time.at(0)) } },
    -> { { 'map-1.json.gz' => map_json(1), 'map-2.json.gz' => 'broken JSON' } },
  ].each_with_index do |build_entries, index|
    it "空・破損・古い・異なるコミットの断片をマップへ採用しない（#{index}）" do
      jobs
      entries = instance_exec(&build_entries)
      allow(@http).to receive(:get).with('/projects/42/jobs/1/artifacts').and_return(archive(entries))
      expect_failure
    end
  end

  it '壊れたZIPでも既存マップを維持する' do
    jobs
    allow(@http).to receive(:get).with('/projects/42/jobs/1/artifacts').and_return('truncated ZIP')
    expect_failure
  end
  [
    { 'edges' => [[1]] },
    { 'edges' => [[-1]] },
    { 'edges' => [[nil]] },
    { 'edges' => [[0.0]] },
    { 'edges' => [0] },
    { 'edges' => [] },
    { 'edges' => nil },
    { 'sources' => ['lib/1.rb', 'lib/1.rb'], 'edges' => [[0], []] },
    { 'sources' => [nil] },
    { 'sources' => {} },
    { 'specs' => ['spec/1_spec.rb', 'spec/1_spec.rb'] },
    { 'specs' => [nil] },
    { 'specs' => {} },
  ].each do |invalid_graph|
    it "不正なグラフ#{invalid_graph.inspect}を公開せず既存マップを維持する" do
      jobs
      invalid = JSON.generate(JSON.parse(map_json).merge(invalid_graph))
      allow(@http).to receive(:get).with('/projects/42/jobs/1/artifacts')
        .and_return(archive('map-1.json.gz' => map_json, 'map-2.json.gz' => invalid))
      expect_failure
    end
  end

end
