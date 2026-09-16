RSpec.describe RspecTia::Audit do
  # 全実行で落ちたspecを表す最小のダブル
  def report(failed)
    instance_double(RspecTia::JunitReport, failed_files: Set.new(failed), validation_errors: [])
  end

  it '失敗specがすべて予測に含まれていれば取りこぼしなし' do
    result = described_class.new(
      junit_report: report(%w(spec/models/user_spec.rb)),
      predicted_specs: %w(spec/models/user_spec.rb spec/jobs/import_job_spec.rb),
    ).call

    expect(result).to be_ok
    expect(result.missed_specs).to be_empty
    expect(result.summary).to match(/取りこぼしなし/)
  end

  it '予測に含まれていない失敗specを取りこぼしとして報告する' do
    result = described_class.new(
      junit_report: report(%w(spec/models/user_spec.rb spec/requests/users_request_spec.rb)),
      predicted_specs: %w(spec/models/user_spec.rb),
    ).call

    expect(result).not_to be_ok
    expect(result.missed_specs.to_a).to eq %w(spec/requests/users_request_spec.rb)
    expect(result.summary).to include 'spec/requests/users_request_spec.rb'
  end

  it '失敗が1件も無ければ取りこぼしなし' do
    result = described_class.new(junit_report: report([]), predicted_specs: []).call

    expect(result).to be_ok
  end
end
