RSpec.describe RspecTia::Predictor do
  # 実在チェックが入るため、一時ディレクトリに実ファイルを置いて検証する
  PROJECT_FILES = %w(
    spec/models/user_spec.rb
    spec/models/v2/sell_case_spec.rb
    spec/jobs/import_job_spec.rb
    spec/requests/api/v2/users_request_spec.rb
    spec/requests/sell_cases_request_spec.rb
  ).freeze

  def build(root, map, overrides = {})
    config = RspecTia::Configuration.new({
      'full_run' => {
        'paths' => %w(Gemfile.lock config/**/*),
        'max_changed_files' => 100,
      },
      'static_mapping' => [
        { 'source' => 'app/(models|jobs)/(.+)\.rb', 'test' => 'spec/%s/%s_spec.rb' },
        { 'source' => 'app/views/([^/]+)/.+', 'test' => 'spec/requests/%s_request_spec.rb' },
      ],
    }.merge(overrides), root: root)
    described_class.new(config: config, map: map)
  end

  def context(changed_files, **attrs)
    RspecTia::Context.new(merge_request: true, changed_files: changed_files, **attrs)
  end

  def fresh_map
    RspecTia::Map.new(generated_at: Time.now)
  end

  it 'カバレッジマップの逆引きでspecを選ぶ' do
    with_project(PROJECT_FILES) do |root|
      map = fresh_map
        .add('spec/requests/api/v2/users_request_spec.rb', %w(app/models/user.rb))
        .add('spec/models/user_spec.rb', %w(app/models/user.rb))
        .add('spec/jobs/import_job_spec.rb', %w(app/jobs/import_job.rb))

      result = build(root, map).call(context(%w(app/models/user.rb)))

      expect(result).not_to be_full_run
      expect(result.specs).to eq %w(spec/models/user_spec.rb spec/requests/api/v2/users_request_spec.rb)
    end
  end

  it 'マップに載っていない新規ファイルは静的マッピングで拾う' do
    with_project(PROJECT_FILES) do |root|
      map = fresh_map.add('spec/models/user_spec.rb', %w(app/models/user.rb))

      result = build(root, map).call(context(%w(app/models/v2/sell_case.rb)))

      expect(result.specs).to eq %w(spec/models/v2/sell_case_spec.rb)
    end
  end

  it 'カバレッジに現れないビューも静的マッピングで拾う' do
    with_project(PROJECT_FILES) do |root|
      map = fresh_map.add('spec/models/user_spec.rb', %w(app/models/user.rb))

      result = build(root, map).call(context(%w(app/views/sell_cases/index.html.haml)))

      expect(result.specs).to eq %w(spec/requests/sell_cases_request_spec.rb)
    end
  end

  it '変更されたspecそのものは無条件に対象に入れる' do
    with_project(PROJECT_FILES) do |root|
      map = fresh_map.add('spec/models/user_spec.rb', %w(app/models/user.rb))

      result = build(root, map).call(context(%w(spec/jobs/import_job_spec.rb)))

      expect(result.specs).to eq %w(spec/jobs/import_job_spec.rb)
    end
  end

  it '3つの経路の和集合を返す' do
    with_project(PROJECT_FILES) do |root|
      map = fresh_map.add('spec/requests/api/v2/users_request_spec.rb', %w(app/models/user.rb))

      result = build(root, map).call(
        context(%w(app/models/user.rb app/jobs/import_job.rb spec/models/v2/sell_case_spec.rb)),
      )

      expect(result.specs).to eq %w(
        spec/jobs/import_job_spec.rb
        spec/models/user_spec.rb
        spec/models/v2/sell_case_spec.rb
        spec/requests/api/v2/users_request_spec.rb
      )
    end
  end

  it '削除されたspecは実行対象から外す（存在しないパスを渡すとrspecが落ちるため）' do
    with_project(PROJECT_FILES) do |root|
      # 静的マッピングが拾わないパスを使い、マップ由来の候補だけで検証する
      map = fresh_map.add('spec/models/deleted_spec.rb', %w(app/lib/foo.rb))

      result = build(root, map).call(context(%w(app/lib/foo.rb)))

      expect(result.specs).to be_empty
    end
  end

  it '影響するspecが無ければ空を返す（ジョブ側で早期終了できるようにするため）' do
    with_project(PROJECT_FILES) do |root|
      result = build(root, fresh_map.add('spec/models/user_spec.rb', %w(app/models/user.rb)))
        .call(context(%w(README.md)))

      expect(result).not_to be_full_run
      expect(result.specs).to be_empty
    end
  end

  describe '全実行になる場合' do
    it '理由と、全specの一覧を返す' do
      with_project(PROJECT_FILES) do |root|
        map = fresh_map.add('spec/models/user_spec.rb', %w(app/models/user.rb))

        result = build(root, map).call(context(%w(Gemfile.lock)))

        expect(result).to be_full_run
        expect(result.reason).to match(/全実行対象のファイル/)
        expect(result.specs).to match_array PROJECT_FILES
      end
    end

    it 'マップが古ければ全実行にする' do
      with_project(PROJECT_FILES) do |root|
        stale = RspecTia::Map.new(generated_at: Time.now - (30 * 24 * 60 * 60))
          .add('spec/models/user_spec.rb', %w(app/models/user.rb))

        result = build(root, stale).call(context(%w(app/models/user.rb)))

        expect(result).to be_full_run
        expect(result.reason).to match(/古い/)
      end
    end
  end
end
