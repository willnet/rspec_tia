# rspec_tia

RSpec向けの Test Impact Analysis。コードカバレッジからspecファイル単位の依存マップを作り、変更されたファイルに影響するspecだけを選び出す。

> 開発中（v0.1.0 未リリース）。インターフェースは変わりうる。

## 仕組み

2つのフェーズに分かれる。

**1. マップ生成（デフォルトブランチで定期実行）**

`Coverage.start(lines: true)` をアプリのロードより前に起動し、specファイルが切り替わるたびに `Coverage.result(stop: false, clear: true)` を取る。クリア付きで取れば「返ってきた結果 = そのspecが触ったファイル」になるので、差分計算が要らない。

**2. 予測（MRのCIで実行）**

変更ファイルからマップを逆引きし、実行すべきspecを決める。カバレッジで検出できない変更（依存gem・CI定義・migration等）は、設定に列挙して全実行に倒す。

### 設計上の判断

- **`oneshot_lines` は使わない。** clear しても一度記録された行が再記録されず、最初にその行を通ったspecが依存を専有してマップが壊れる。`lines: true` を使う。
- **粒度はspecファイル単位。** example単位にすると呼び出し回数が2桁増える。specファイル単位なら実測で 25〜31ms × specファイル数に収まる（1,966 spec のRailsアプリで合計53秒）。
- **eager_load 対策として、suite開始時に1回 clear する。** eager_load が有効だとboot時点で全クラス定義行が実行済みになるため、これを捨てないと全specが全ファイルに依存してしまう。
- **ActiveRecord の通知でモデルを補完する。** 次のようなクラスはロード後に実行される行がなく、カバレッジには決して現れない。

  ```ruby
  class Account < ApplicationRecord
    belongs_to :user
  end
  ```

  `sql.active_record` / `instantiation.active_record` を購読してモデル名を拾い、`Module.const_source_location` で定義ファイルに変換して依存に足す。あるRailsアプリでの実測では、この補完で依存エッジが 402 → 594（+48%）に増えた。補完がないと約1/3の依存を取りこぼす。

## インストール

```ruby
group :test do
  gem 'rspec_tia'
end
```

## 設定

`.rspec_tia.yml` をプロジェクトルートに置く。

```yaml
spec_glob: 'spec/**/*_spec.rb'
# 全実行と判定したときに select が出力する1行
full_run_token: spec

map:
  fragment_dir: tmp/rspec_tia/fragments
  path: tmp/rspec_tia/map.json.gz
  max_age_days: 3

# カバレッジで検出できない変更。ここに該当したら全specを実行する
full_run:
  paths:
    - Gemfile.lock
    - config/**/*
    - db/**/*
    - spec/rails_helper.rb
    - spec/support/**/*
    - .gitlab-ci.yml
  max_changed_files: 300
  labels:
    - 'pipeline:run-all-rspec'
  commit_message_tokens:
    - '[run-all-rspec]'

# マップに載らない新規ファイル・テンプレート・拾えなかったcode-lessクラスの補完。
# source の後方参照を test の %s に順に埋める。解決先が実在しない場合は捨てる
static_mapping:
  - source: 'app/(models|jobs)/(.+)\.rb'
    test: 'spec/%s/%s_spec.rb'
  - source: 'app/controllers/(.+)_controller\.rb'
    test: 'spec/requests/%s_request_spec.rb'
  - source: 'app/views/([^/]+)/.+'
    test: 'spec/requests/%s_request_spec.rb'

ci:
  adapter: auto  # auto | gitlab | git
```

パスのパターンは `File.fnmatch?(FNM_PATHNAME | FNM_EXTGLOB)` で判定する。GitLab CI の `rules:changes` と同じ記法なので `config/**/*` のように書く（`config/**` はネストしたパスにマッチしない）。

## 使い方

### マップを生成する

```bash
RUBYOPT="-rrspec_tia/boot" bundle exec rspec \
  --require rspec_tia/formatter --format RspecTia::Formatter
```

`RUBYOPT` で最初期に読ませるのが必須。アプリのロード前に計測を始めないと、どのファイルも追跡対象にならない。

断片は `map.fragment_dir` に `map-<ノード>-<プロセス>.json.gz` として出る（`CI_NODE_INDEX` / `TEST_ENV_NUMBER` から命名）。並列実行しても互いに上書きしない。

```bash
bundle exec rspec-tia map merge
```

### GitLabのマップartifact

`ci.gitlab.map_job_name`にはマップ生成ジョブ名を設定し、各ジョブで`map.fragment_dir`全体をartifactに保存する。取得側はjob artifactのZIPを読み、`ci.gitlab.map_artifact_glob`（既定`tmp/rspec_tia/fragments`）配下の`.json`/`.json.gz`断片を列挙する。ファイル名やプロセス数を推測しないため、単一プロセス、CIノード並列、`TEST_ENV_NUMBER`並列、CIノード未設定時のPID形式を扱える。

`map_artifact_glob`はプロジェクトルートからの相対ディレクトリ、glob、または断片ファイルの相対パスを指定できる。`RSPEC_TIA_FRAGMENT_PATH`で出力を変更した場合は、そのファイルをartifactに含め、`map_artifact_glob`も合わせる。artifactの404や通信失敗は取得失敗とする。

### 実行すべきspecを選ぶ

次は、プロジェクトルートで実行するBashのCIスクリプト例。予測が正常に0件ならRSpecを起動せず終了し、予測に失敗した場合はジョブも失敗させる。

```bash
#!/usr/bin/env bash
bundle exec rspec-tia select > specs.txt || exit "$?"
[ -s specs.txt ] || exit 0

specs=()
while IFS= read -r spec; do
  specs+=("$spec")
done < specs.txt
bundle exec rspec "${specs[@]}"
```

出力の1行を1引数として渡すため、パス内の空白・バックスラッシュ・ワイルドカード文字をシェルが分割・展開しない。改行を含むファイル名には対応しない。

全実行と判定した場合は `full_run_token`（既定 `spec`）が1行だけ出る。この例ではそれも1引数としてRSpecに渡す。カスタム値には、全対象を含むディレクトリ等、RSpecが1引数で受け取れる値を設定する。外部の分割スクリプト専用のトークンを使う場合は、そのスクリプト側で全実行へ変換する。

CIから差分を取らず、手元のファイル一覧で試すこともできる。過去のマージコミットを流して削減率と取りこぼしを事前に測るときに使う。

```bash
git diff --name-only HEAD~1 | bundle exec rspec-tia select --changed-files-from -
```

### そのほか

```bash
bundle exec rspec-tia map fetch   # CIから断片を取得してまとめる
bundle exec rspec-tia audit --junit tmp/junit --predicted specs.txt
bundle exec rspec-tia doctor      # 設定と環境の妥当性を確認する
```

`audit` は、全実行で落ちたspecが予測に含まれていたかを検証する。含まれていなければ終了コード1を返す。予測実行を本番で使うなら、この検証を回し続けないと「静かに落とすようになった」ことに気付けない。

## 既知の限界

- **テンプレート（HAML/ERB）はカバレッジに現れない。** `static_mapping` で対応づける。
- **メソッド本体を持たないファイルのうち、ActiveRecordモデル以外は拾えない。** `static_mapping` で補う。
- **外部サービスやデータファイルへの依存は検出できない。** `full_run.paths` に列挙する。
- **共有コードが巨大だと効果が出にくい。** 多数のspecから使われるconcernやモジュールを変更すると、結局そのspec群がすべて選ばれる。

## ライセンス

MIT
