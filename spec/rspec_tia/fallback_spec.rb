RSpec.describe RspecTia::Fallback do
  subject(:fallback) { described_class.new(config: config, map: map) }

  let(:config) do
    RspecTia::Configuration.new({
      'map' => { 'max_age_days' => 3 },
      'full_run' => {
        'paths' => %w(Gemfile.lock config/**/* db/**/* spec/support/**/* .gitlab/ci/**/*),
        'max_changed_files' => 5,
        'labels' => %w(pipeline:run-all-rspec),
        'commit_message_tokens' => ['[run-all-rspec]'],
      },
    })
  end

  let(:map) { RspecTia::Map.new(generated_at: Time.now).add('spec/a_spec.rb', %w(app/x.rb)) }

  def context(**attrs)
    RspecTia::Context.new(merge_request: true, changed_files: %w(app/x.rb), **attrs)
  end

  it '通常のMRでは全実行にしない' do
    expect(fallback.reason(context)).to be_nil
  end

  it 'MR以外のパイプラインでは全実行にする' do
    expect(fallback.reason(context(merge_request: false))).to match(/Not a merge request pipeline/)
  end

  it 'マップが無い場合は全実行にする' do
    empty = described_class.new(config: config, map: RspecTia::Map.new(generated_at: Time.now))

    expect(empty.reason(context)).to match(/No coverage map available/)
  end

  it 'マップが古い場合は全実行にする' do
    stale = RspecTia::Map.new(generated_at: Time.now - (10 * 24 * 60 * 60)).add('spec/a_spec.rb', %w(app/x.rb))

    expect(described_class.new(config: config, map: stale).reason(context)).to match(/Coverage map is stale/)
  end

  it '全実行ラベルが付いていたら全実行にする' do
    expect(fallback.reason(context(labels: %w(bug pipeline:run-all-rspec)))).to match(/Full-run label/)
  end

  it 'コミットメッセージに指定があれば全実行にする' do
    expect(fallback.reason(context(commit_message: 'fix: なにか [run-all-rspec]'))).to match(/commit message/)
  end

  it '変更ファイル数が閾値を超えたら全実行にする' do
    many = (1..6).map { |i| "app/#{i}.rb" }

    expect(fallback.reason(context(changed_files: many))).to match(/Too many changed files/)
  end

  describe '全実行対象のパス' do
    {
      'Gemfile.lock' => '依存gemの変更はカバレッジに現れない',
      'config/initializers/foo.rb' => 'configはカバレッジ集計から除外されている',
      'db/migrate/20260101_add_foo.rb' => 'migrationはカバレッジに現れない',
      'spec/support/helper.rb' => '全specに無条件requireされる',
      '.gitlab/ci/test_stage_rails.yml' => 'CI定義そのもの',
    }.each do |path, why|
      it "#{path} の変更で全実行にする（#{why}）" do
        expect(fallback.reason(context(changed_files: [path]))).to match(/Full-run path changed/)
      end
    end

    it 'ネストしていないパスもネストしたパスも同じルールで拾える' do
      expect(fallback.reason(context(changed_files: %w(config/routes.rb)))).to match(/Full-run path/)
      expect(fallback.reason(context(changed_files: %w(config/routes/api.rb)))).to match(/Full-run path/)
    end

    it '該当ファイルが多い場合は理由を省略表示する' do
      # Raise the limit for this test so the changed-file count check does not trigger first.
      loose = RspecTia::Configuration.new({
        'full_run' => { 'paths' => %w(config/**/*), 'max_changed_files' => 100 },
      })
      changed = (1..8).map { |i| "config/#{i}.rb" }

      reason = described_class.new(config: loose, map: map).reason(context(changed_files: changed))

      expect(reason).to match(/and 3 more/)
    end
  end
end
