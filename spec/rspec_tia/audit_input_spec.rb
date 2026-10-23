require 'rspec_tia/cli'

RSpec.describe '監査のJUnit入力検証' do
  cases = {
    'ディレクトリ不在' => nil,
    'XMLゼロ件' => {},
    '破損XMLと正常XMLの混在' => { 'ok.xml' => '<testsuite/>', 'broken.xml' => '<testsuite>' },
    '失敗のfile属性がない' => { 'a.xml' => '<testsuite><testcase><failure/></testcase></testsuite>' },
    'errorのfile属性が空' => { 'a.xml' => '<testsuite><testcase file=" "><error/></testcase></testsuite>' },
    '空ファイル' => { 'a.xml' => '' },
    'JUnit以外のXML' => { 'a.xml' => '<unrelated/>' },
  }

  cases.each do |name, files|
    it "#{name}を監査成功としない" do
      Dir.mktmpdir do |root|
        dir = File.join(root, 'junit')
        FileUtils.mkdir_p(dir) if files
        files&.each { |path, xml| File.write(File.join(dir, path), xml) }
        predicted = File.join(root, 'predicted.txt')
        File.write(predicted, "spec/a_spec.rb\n")
        report = RspecTia::JunitReport.load_dir(dir)
        allow(report).to receive(:warn)
        result = RspecTia::Audit.new(junit_report: report, predicted_specs: ['spec/a_spec.rb']).call
        expect(result).not_to be_ok
        expect(result.validation_errors).not_to be_empty
        expect(result.summary).to include('Cannot validate audit')
        expect(result.summary).not_to include('No missed failures')
        expect { expect(RspecTia::Cli.start(['audit', '--junit', dir, '--predicted', predicted])).to eq(1) }
          .to output(/Cannot validate audit/).to_stderr
      end
    end
  end

  ['<testsuite/>', '<testsuites><testsuite/></testsuites>',
   '<testsuite><testcase file="spec/a_spec.rb"/></testsuite>'].each do |xml|
    it "正常な空suiteまたは失敗ゼロ件は成功する: #{xml}" do
      Dir.mktmpdir do |root|
        File.write(File.join(root, 'a.xml'), xml)
        report = RspecTia::JunitReport.load_dir(root)
        result = RspecTia::Audit.new(junit_report: report, predicted_specs: []).call
        expect(result).to be_ok
        expect(report.parsed_file_count).to eq(1)
        expect(report.validation_errors).to eq([])
        predicted = File.join(root, 'predicted.txt')
        File.write(predicted, '')
        expect { expect(RspecTia::Cli.start(['audit', '--junit', root, '--predicted', predicted])).to eq(0) }
          .to output(/No missed failures/).to_stderr
      end
    end
  end

  it '正常なJUnitの取りこぼしはCLIで引き続き検出する' do
    Dir.mktmpdir do |root|
      File.write(File.join(root, 'a.xml'), '<testsuite><testcase file="./spec/a_spec.rb"><failure/></testcase></testsuite>')
      predicted = File.join(root, 'predicted.txt')
      File.write(predicted, "spec/b_spec.rb\n")
      expect { expect(RspecTia::Cli.start(['audit', '--junit', root, '--predicted', predicted])).to eq(1) }
        .to output(/Prediction missed 1 failing specs/).to_stderr
    end
  end

  it '読み取りに失敗したファイルを記録し、正常なファイルの集計を維持する' do
    Dir.mktmpdir do |root|
      ok = File.join(root, 'ok.xml')
      File.write(ok, '<testsuite><testcase file="spec/a_spec.rb" time="2"><failure/></testcase></testsuite>')
      report = RspecTia::JunitReport.new([File.join(root, 'missing.xml'), ok])
      expect { report.durations }.to output(/Could not read junit.xml/).to_stderr
      expect(report.durations).to eq('spec/a_spec.rb' => 2.0)
      expect(report.failed_files).to contain_exactly('spec/a_spec.rb')
      expect(report.parsed_file_count).to eq(1)
      expect(report.validation_errors.size).to eq(1)
    end
  end
end
