require 'open3'
require 'rbconfig'
require 'rspec_tia/cli'

RSpec.describe RspecTia::Ci::Git do
  def git(root, *args)
    output, status = Open3.capture2e('git', '-c', 'commit.gpgsign=false', '-c', 'user.name=Test',
                                   '-c', 'user.email=test@example.com', *args, chdir: root)
    raise output unless status.success?
    output
  end

  around do |example|
    original = ENV['RSPEC_TIA_DIFF_BASE']
    ENV['RSPEC_TIA_DIFF_BASE'] = 'base'
    example.run
  ensure
    ENV['RSPEC_TIA_DIFF_BASE'] = original
  end

  def with_repository
    with_project(['spec/a_spec.rb', 'lib/a.rb']) do |root|
      git(root, 'init', '-q')
      git(root, 'add', '.')
      git(root, 'commit', '-qm', 'Initial files')
      git(root, 'branch', 'base')
      config = RspecTia::Configuration.new({}, root: root)
      map = RspecTia::Map.new(generated_at: Time.now)
      map.add('spec/a_spec.rb', ['lib/a.rb'])
      map.dump(config.map_path)
      File.write(File.join(root, '.rspec_tia.yml'), "ci:\n  adapter: git\n")
      yield root, config, map
    end
  end

  it '取得に成功した空の差分は正常なゼロ件予測になる' do
    with_repository do |_root, config, map|
      context = described_class.new(config).context
      expect(context.changed_files).to eq([])
      result = RspecTia::Predictor.new(config: config, map: map).call(context)
      expect(result).not_to be_full_run
      expect(result.specs).to eq([])
    end
  end

  ['missing', 'unrelated'].each do |base|
    it "#{base}のbaseでは原因を残して失敗し、CLIからも正常なゼロ件を返さない" do
      with_repository do |root, config, _map|
        if base == 'unrelated'
          git(root, 'checkout', '--orphan', 'unrelated')
          git(root, 'commit', '-qm', 'Unrelated root')
          git(root, 'checkout', 'base')
        end
        ENV['RSPEC_TIA_DIFF_BASE'] = base
        expect { described_class.new(config).context }
          .to raise_error(described_class::CommandError, /git diff.*#{base}/)

        cli = File.expand_path('../../../exe/rspec-tia', __dir__)
        lib = File.expand_path('../../../lib', __dir__)
        stdout, stderr, status = Open3.capture3(RbConfig.ruby, '-I', lib, cli, 'select', '--root', root)
        expect(status.exitstatus).to eq(1)
        expect(stdout).to eq('')
        expect(stderr).to include('git diff', base, '失敗しました')
        expect(stderr).not_to match(/\tfrom /)
      end
    end
  end
  [false, true].each do |modify|
    it "リネーム前後の依存を選択する（内容変更: #{modify}）" do
      with_repository do |root, config, map|
        File.write(File.join(root, 'lib/a.rb'), (1..20).map { |n| "# line #{n}\n" }.join)
        git(root, 'add', 'lib/a.rb')
        git(root, 'commit', '-qm', 'Source with rename similarity')
        git(root, 'branch', '-f', 'base')
        git(root, 'mv', 'lib/a.rb', 'lib/new.rb')
        File.open(File.join(root, 'lib/new.rb'), 'a') { |f| f.puts('# changed') } if modify
        git(root, 'commit', '-am', 'Rename source')
        context = described_class.new(config).context
        expect(context.changed_files).to contain_exactly('lib/a.rb', 'lib/new.rb')
        result = RspecTia::Predictor.new(config: config, map: map).call(context)
        expect(result).not_to be_full_run
        expect(result.specs).to eq(['spec/a_spec.rb'])
      end
    end
  end

  it '追加・削除・通常変更と空白や改行を含むパスを保持する' do
    with_repository do |root, config, _map|
      paths = ["lib/ space.rb ", "lib/line\nbreak.rb", "lib/tab\tname.rb"]
      paths.each { |path| File.write(File.join(root, path), '# new') }
      File.write(File.join(root, 'lib/a.rb'), '# modified')
      File.delete(File.join(root, 'spec/a_spec.rb'))
      git(root, 'add', '-A', '--', 'lib', 'spec')
      git(root, 'commit', '-qm', 'Mixed changes')
      expect(described_class.new(config).changed_files)
        .to contain_exactly(*paths, 'lib/a.rb', 'spec/a_spec.rb')
    end
  end

end
