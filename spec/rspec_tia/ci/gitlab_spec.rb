require 'zip'

RSpec.describe RspecTia::Ci::Gitlab do
  subject(:adapter) { described_class.new(config) }

  let(:config) { RspecTia::Configuration.new({}) }
  let(:http) { instance_double(RspecTia::Http) }

  before { allow(adapter).to receive(:http).and_return(http) }

  # ENVを直接いじらず、テストの中でだけ差し替える
  def with_env(vars)
    original = vars.keys.to_h { |key| [key, ENV.fetch(key, nil)] }
    vars.each { |key, value| ENV[key] = value }
    yield
  ensure
    original.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end

  describe '#merge_request?' do
    it 'MRのパイプラインのときだけ真になる' do
      with_env('CI_PIPELINE_SOURCE' => 'merge_request_event') { expect(adapter).to be_merge_request }
      with_env('CI_PIPELINE_SOURCE' => 'push') { expect(adapter).not_to be_merge_request }
      with_env('CI_PIPELINE_SOURCE' => nil) { expect(adapter).not_to be_merge_request }
    end
  end

  describe '#labels' do
    it 'GitLabが渡すカンマ区切りのラベルを読む（API呼び出しを避けるため）' do
      with_env('CI_MERGE_REQUEST_LABELS' => 'bug, pipeline:run-all-rspec ,') do
        expect(adapter.labels).to eq %w(bug pipeline:run-all-rspec)
      end
    end

    it 'ラベルが無ければ空' do
      with_env('CI_MERGE_REQUEST_LABELS' => nil) { expect(adapter.labels).to eq [] }
    end
  end

  describe '#changed_files' do
    let(:diffs) do
      [
        { 'new_path' => 'app/models/user.rb', 'old_path' => 'app/models/user.rb' },
        { 'new_path' => 'app/models/new.rb', 'old_path' => 'app/models/new.rb', 'new_file' => true },
        { 'new_path' => 'app/models/after.rb', 'old_path' => 'app/models/before.rb', 'renamed_file' => true },
        { 'new_path' => 'app/models/gone.rb', 'old_path' => 'app/models/gone.rb', 'deleted_file' => true },
      ]
    end

    it 'MRのdiffをAPIから取る（浅いクローンではgit diffが使えないため）' do
      with_env('CI_PROJECT_ID' => '42', 'CI_MERGE_REQUEST_IID' => '7') do
        expect(http).to receive(:get_json)
          .with(a_string_including('/projects/42/merge_requests/7/diffs'))
          .and_return(diffs)

        expect(adapter.changed_files).to contain_exactly(
          'app/models/user.rb',
          'app/models/new.rb',
          'app/models/after.rb',
          'app/models/before.rb',
          'app/models/gone.rb',
        )
      end
    end

    it 'リネームでは旧パスの依存も実行対象に含める' do
      with_env('CI_PROJECT_ID' => '42', 'CI_MERGE_REQUEST_IID' => '7') do
        allow(http).to receive(:get_json).and_return([diffs[2]])

        expect(adapter.changed_files).to include 'app/models/before.rb'
      end
    end

    it 'MRのiidが無ければAPIを叩かない' do
      with_env('CI_MERGE_REQUEST_IID' => nil) do
        expect(http).not_to receive(:get_json)
        expect(adapter.changed_files).to eq []
      end
    end
  end

  describe 'マップ断片の取得' do
    let(:pipeline) { { 'id' => 100, 'created_at' => '2026-09-08T00:00:00Z' } }

    before do
      allow(config).to receive(:gitlab_options).and_return(
        'map_ref' => 'master',
        'map_pipeline_source' => 'schedule',
        'map_job_name' => 'rails_spec_tia_map',
        'map_artifact_glob' => 'tmp/rspec_tia/fragments',
      )
    end

    it '対象ジョブのartifactアーカイブに含まれる断片を取得する' do
      with_env('CI_PROJECT_ID' => '42') do
        allow(http).to receive(:get_json)
          .with(a_string_including('/pipelines?ref=master')).and_return([pipeline])
        allow(http).to receive(:get_json)
          .with(a_string_including('/pipelines/100/jobs')).and_return(
            [
              { 'id' => 1, 'name' => 'rails_spec_tia_map', 'status' => 'success' },
              { 'id' => 2, 'name' => 'rails_rubocop' },
            ],
            [],
          )

        archive = Zip::OutputStream.write_buffer do |zip|
          %w(map-3-1.json.gz map-3-2.json.gz).each do |name|
            zip.put_next_entry("tmp/rspec_tia/fragments/#{name}")
            map = RspecTia::Map.new(generated_at: Time.now).add("spec/#{name}_spec.rb", ['lib/a.rb'])
            zip.write(JSON.generate(map.to_h))
          end
          zip.put_next_entry('other/report.xml')
          zip.write('<testsuite/>')
        end.string
        allow(http).to receive(:get).with('/projects/42/jobs/1/artifacts').and_return(archive)

        Dir.mktmpdir do |dir|
          saved = adapter.fetch_map_fragments(dir)

          expect(saved.map { |path| File.basename(path) })
            .to eq %w(job_1_0_map-3-1.json.gz job_1_1_map-3-2.json.gz)
          # 対象外のジョブにはリクエストしない
          expect(http).not_to have_received(:get).with(a_string_including('/jobs/2/'))
        end
      end
    end

    it 'マップ生成パイプラインが無ければ空を返す（予測側で全実行に倒れる）' do
      with_env('CI_PROJECT_ID' => '42') do
        allow(http).to receive(:get_json).with(a_string_including('/pipelines?')).and_return([])

        Dir.mktmpdir do |dir|
          expect { @saved = adapter.fetch_map_fragments(dir) }
            .to output(/No map-generation pipeline found/).to_stderr
          expect(@saved).to eq []
        end
      end
    end
  end
end
