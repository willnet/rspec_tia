require 'rspec_tia/cli'

RSpec.describe '全実行予測の監査' do
  def audit(root, predicted, *options)
    path = File.join(root, 'predicted.txt')
    File.write(path, predicted)
    RspecTia::Cli.start(['audit', '--root', root, '--junit', File.join(root, 'junit'),
                         '--predicted', path, *options])
  end

  around do |example|
    Dir.mktmpdir do |root|
      @root = root
      FileUtils.mkdir_p(File.join(root, 'junit'))
      File.write(File.join(root, 'junit/result.xml'),
                 '<testsuite><testcase file="./spec/a_spec.rb"><failure/></testcase></testsuite>')
      example.run
    end
  end

  it '既定トークンを全実行として認識する' do
    expect { expect(audit(@root, "spec\n")).to eq(0) }.to output(/No missed failures/).to_stderr
  end

  it '--rootの設定でカスタムトークンを認識する' do
    File.write(File.join(@root, '.rspec_tia.yml'), 'full_run_token: all-tests')
    expect { expect(audit(@root, "all-tests\n")).to eq(0) }.to output(/No missed failures/).to_stderr
  end

  it '--configを優先してカスタムトークンを認識する' do
    File.write(File.join(@root, '.rspec_tia.yml'), 'full_run_token: other')
    config = File.join(@root, 'custom.yml')
    File.write(config, 'full_run_token: all-tests')
    expect { expect(audit(@root, "all-tests\n", '--config', config)).to eq(0) }
      .to output(/No missed failures/).to_stderr
  end

  it '通常の一覧とトークンの部分一致を全実行にしない' do
    ["spec/b_spec.rb\n", "spec\nspec/b_spec.rb\n", "spec-extra\n"].each do |prediction|
      expect { expect(audit(@root, prediction)).to eq(1) }.to output(/Prediction missed/).to_stderr
    end
  end

  it '全実行でもJUnitが欠落・破損・特定不能なら成功しない' do
    [nil, '<testsuite>', '<testsuite><testcase><failure/></testcase></testsuite>'].each do |xml|
      path = File.join(@root, 'junit/result.xml')
      xml ? File.write(path, xml) : File.delete(path)
      expect { expect(audit(@root, "spec\n")).to eq(1) }.to output(/Cannot validate audit/).to_stderr
    end
  end
end
