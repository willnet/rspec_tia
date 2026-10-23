RSpec.describe RspecTia::JunitReport do
  def write_junit(dir, name, body)
    path = File.join(dir, name)
    File.write(path, body)
    path
  end

  # rspec_junit_formatter emits the file attribute in the form "./spec/...".
  let(:xml_a) do
    <<~XML
      <?xml version="1.0" encoding="UTF-8"?>
      <testsuite>
        <testcase file="./spec/models/user_spec.rb" time="1.5" name="a"/>
        <testcase file="./spec/models/user_spec.rb" time="0.5" name="b"/>
        <testcase file="./spec/jobs/import_job_spec.rb" time="2.0" name="c"/>
      </testsuite>
    XML
  end

  let(:xml_b) do
    <<~XML
      <?xml version="1.0" encoding="UTF-8"?>
      <testsuite>
        <testcase file="./spec/requests/users_request_spec.rb" time="3.0" name="d">
          <failure message="boom">detail</failure>
        </testcase>
        <testcase file="./spec/models/user_spec.rb" time="1.0" name="e">
          <error message="kaboom">detail</error>
        </testcase>
      </testsuite>
    XML
  end

  it 'specファイル単位に実行時間を合算する（プロセスをまたいでも合算する）' do
    Dir.mktmpdir do |dir|
      write_junit(dir, 'a.xml', xml_a)
      write_junit(dir, 'b.xml', xml_b)

      durations = described_class.load_dir(dir).durations

      expect(durations['spec/models/user_spec.rb']).to eq 3.0
      expect(durations['spec/jobs/import_job_spec.rb']).to eq 2.0
      expect(durations['spec/requests/users_request_spec.rb']).to eq 3.0
    end
  end

  it 'failure と error のどちらも失敗として集める' do
    Dir.mktmpdir do |dir|
      write_junit(dir, 'a.xml', xml_a)
      write_junit(dir, 'b.xml', xml_b)

      expect(described_class.load_dir(dir).failed_files)
        .to contain_exactly('spec/requests/users_request_spec.rb', 'spec/models/user_spec.rb')
    end
  end

  it '壊れたxmlがあっても他のファイルの集計は続ける（ジョブのタイムアウトで途中で切れるため）' do
    Dir.mktmpdir do |dir|
      write_junit(dir, 'a.xml', xml_a)
      write_junit(dir, 'broken.xml', '<testsuite><testcase file="./spec/x_spec.rb"')

      report = described_class.load_dir(dir)

      expect { report.durations }.to output(/Could not read junit.xml/).to_stderr
      expect(report.durations['spec/models/user_spec.rb']).to eq 2.0
    end
  end

  it 'junit.xmlが無ければ空とみなす' do
    Dir.mktmpdir { |dir| expect(described_class.load_dir(dir)).to be_empty }
  end
end
