module RspecTia
  # 命名規約による「ソースファイル -> specファイル」の変換。
  #
  # カバレッジマップが答えられない次の3つを埋めるために使う。
  #   - マップに載っていない新規追加ファイル
  #   - メソッド本体を持たないファイル（AR通知でも拾えないもの）
  #   - カバレッジに現れないテンプレート（HAML等）
  #
  # ルールは source（正規表現）と test（%s に後方参照を順に埋める雛形。配列可）の組。
  # 解決先が実在しない場合は捨てるので、単複の揺れやタイポによる誤変換は自然に落ちる。
  class StaticMapping
    Rule = Struct.new(:pattern, :templates, keyword_init: true)

    def initialize(rules, root: Dir.pwd)
      @root = root
      @rules = Array(rules).map do |rule|
        Rule.new(
          pattern: Regexp.new("\\A(?:#{Array(rule.fetch('source')).join('|')})\\z"),
          templates: Array(rule.fetch('test')),
        )
      end
    end

    def call(paths)
      paths.flat_map { |path| specs_for(path) }.uniq
    end

    def specs_for(path)
      @rules.flat_map do |rule|
        match = rule.pattern.match(path)
        next [] if match.nil?

        expand(rule.templates, match.captures)
      end.uniq
    end

    private

    def expand(templates, captures)
      templates.filter_map do |template|
        candidate = format_template(template, captures)
        next if candidate.nil?

        candidate if File.exist?(File.join(@root, candidate))
      end
    end

    # 雛形の %s の数と後方参照の数が食い違う設定ミスは、そのルールを無視して続行する。
    # 1つのルールの記述ミスで予測全体を落とさないため
    def format_template(template, captures)
      format(template, *captures)
    rescue ArgumentError, TypeError
      warn "[rspec_tia] static_mapping template placeholders do not match capture groups: #{template.inspect} <- #{captures.inspect}"
      nil
    end
  end
end
