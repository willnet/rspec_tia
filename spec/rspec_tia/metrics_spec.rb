RSpec.describe RspecTia::Metrics do
  SPECS = %w(spec/a_spec.rb spec/b_spec.rb spec/c_spec.rb spec/d_spec.rb).freeze

  def config_for(root)
    RspecTia::Configuration.new({ 'spec_glob' => 'spec/**/*_spec.rb' }, root: root)
  end

  def result(specs:, full_run: false, reason: nil, sources: %w(app/x.rb))
    RspecTia::Predictor::Result.new(full_run: full_run, reason: reason, specs: specs, sources: sources)
  end

  it '件数ベースの削減率を出す' do
    with_project(SPECS) do |root|
      metrics = described_class.new(config: config_for(root), result: result(specs: SPECS.first(1)))

      expect(metrics.to_h).to include(
        'full_run' => false,
        'predicted_spec_count' => 1,
        'total_spec_count' => 4,
        'spec_ratio' => 0.25,
      )
    end
  end

  it 'junit.xmlがあれば実測時間で重み付けした削減率も出す' do
    with_project(SPECS) do |root|
      durations = { 'spec/a_spec.rb' => 1.0, 'spec/b_spec.rb' => 9.0, 'spec/c_spec.rb' => 0.0, 'spec/d_spec.rb' => 0.0 }
      report = instance_double(RspecTia::JunitReport, empty?: false, durations: durations)

      metrics = described_class.new(config: config_for(root), result: result(specs: %w(spec/a_spec.rb)), junit_report: report)

      # 件数では 1/4 = 25% だが、実行時間では 1.0/10.0 = 10%
      expect(metrics.to_h).to include('spec_ratio' => 0.25, 'time_ratio' => 0.1)
      expect(metrics.summary).to include 'Estimated runtime 10.0%'
    end
  end

  it '全実行のときは理由を残す' do
    with_project(SPECS) do |root|
      metrics = described_class.new(
        config: config_for(root),
        result: result(specs: SPECS, full_run: true, reason: 'Gemfile.lock が変更されたため'),
      )

      expect(metrics.to_h).to include('full_run' => true, 'reason' => 'Gemfile.lock が変更されたため')
      expect(metrics.summary).to include 'Gemfile.lock が変更されたため'
    end
  end

  it 'ファイルに書き出せる' do
    with_project(SPECS) do |root|
      config = config_for(root)
      path = described_class.new(config: config, result: result(specs: SPECS.first(2))).write

      expect(JSON.parse(File.read(path))).to include('predicted_spec_count' => 2)
    end
  end
end
