RSpec.describe RspecTia::Map do
  describe '逆引き' do
    it 'ソースファイルから、それを実行したspecを引ける' do
      map = described_class.new
      map.add('spec/a_spec.rb', %w(app/x.rb app/y.rb))
      map.add('spec/b_spec.rb', %w(app/y.rb))

      expect(map.specs_for('app/x.rb').to_a).to eq %w(spec/a_spec.rb)
      expect(map.specs_for('app/y.rb').to_a).to match_array %w(spec/a_spec.rb spec/b_spec.rb)
    end

    it '知らないソースファイルには空を返す' do
      expect(described_class.new.specs_for('app/unknown.rb')).to be_empty
    end

    it '依存が1つも無いspecもspecs には含まれる' do
      map = described_class.new
      map.add('spec/empty_spec.rb', [])

      expect(map.specs).to include 'spec/empty_spec.rb'
      expect(map).not_to be_empty
    end
  end

  describe 'シリアライズ' do
    let(:map) do
      described_class.new(generated_at: Time.utc(2026, 9, 1, 3, 0, 0), commit_sha: 'abc123').tap do |m|
        m.add('spec/a_spec.rb', %w(app/x.rb app/y.rb))
        m.add('spec/b_spec.rb', %w(app/y.rb))
      end
    end

    it 'gzipで書き出して読み戻せる' do
      Dir.mktmpdir do |dir|
        path = map.dump(File.join(dir, 'map.json.gz'))
        loaded = described_class.load(path)

        expect(loaded.specs_for('app/y.rb').to_a).to match_array %w(spec/a_spec.rb spec/b_spec.rb)
        expect(loaded.generated_at).to eq Time.utc(2026, 9, 1, 3, 0, 0)
        expect(loaded.commit_sha).to eq 'abc123'
      end
    end

    it '非圧縮でも読み戻せる' do
      Dir.mktmpdir do |dir|
        path = map.dump(File.join(dir, 'map.json'))
        expect(described_class.load(path).specs_for('app/x.rb').to_a).to eq %w(spec/a_spec.rb)
      end
    end

    it 'format_versionが違うファイルは読まない' do
      Dir.mktmpdir do |dir|
        path = File.join(dir, 'map.json')
        File.write(path, JSON.generate(map.to_h.merge('format_version' => 999)))

        expect { described_class.load(path) }.to raise_error(described_class::FormatError, /999/)
      end
    end

    {
      '壊れたJSON' => '{"format_version":',
      '途中で切れたgzip' => "\x1f\x8b\x08\x00broken".b,
      '不正なgenerated_at' => :invalid_time,
      '文字列でないgenerated_at' => :numeric_time,
    }.each do |name, content|
      it "#{name}はパスを含むFormatErrorにする" do
        Dir.mktmpdir do |dir|
          path = File.join(dir, 'map.json.gz')
          content = JSON.generate(map.to_h.merge('generated_at' => 'yesterday')) if content == :invalid_time
          content = JSON.generate(map.to_h.merge('generated_at' => 0)) if content == :numeric_time
          File.binwrite(path, content)

          expect { described_class.load(path) }.to raise_error(described_class::FormatError, /#{Regexp.escape(path)}/)
        end
      end
    end
  end

  describe '#merge!' do
    it '断片をまとめられる' do
      a = described_class.new.add('spec/a_spec.rb', %w(app/x.rb))
      b = described_class.new.add('spec/b_spec.rb', %w(app/x.rb app/z.rb))

      a.merge!(b)

      expect(a.specs).to match_array %w(spec/a_spec.rb spec/b_spec.rb)
      expect(a.specs_for('app/x.rb').to_a).to match_array %w(spec/a_spec.rb spec/b_spec.rb)
      expect(a.specs_for('app/z.rb').to_a).to eq %w(spec/b_spec.rb)
    end

    it '生成時刻は最も古いものを採用する（鮮度判定を安全側に倒すため）' do
      old = described_class.new(generated_at: Time.utc(2026, 9, 1))
      recent = described_class.new(generated_at: Time.utc(2026, 9, 5))

      expect(recent.merge!(old).generated_at).to eq Time.utc(2026, 9, 1)
    end
  end

  describe '#stale?' do
    it '許容期間を過ぎていたら古いとみなす' do
      map = described_class.new(generated_at: Time.utc(2026, 9, 1))

      expect(map.stale?(max_age_days: 3, now: Time.utc(2026, 9, 3))).to be false
      expect(map.stale?(max_age_days: 3, now: Time.utc(2026, 9, 5))).to be true
    end

    it '生成時刻が不明なら古いとみなす' do
      expect(described_class.new.stale?(max_age_days: 3)).to be true
    end
  end
end
