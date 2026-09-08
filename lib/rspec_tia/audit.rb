require 'set'

module RspecTia
  # 予測の取りこぼしを検証する。
  #
  # 全実行のjunit.xmlで落ちたspecが、同じ変更に対する予測に含まれていたかを見る。
  # 含まれていなければ、その変更は予測できていなかった＝マップか設定に穴がある。
  #
  # 予測実行を本番で使う以上、この検証を回し続けないと「静かに落とすようになった」ことに気付けない。
  class Audit
    Result = Struct.new(:failed_specs, :predicted_specs, :missed_specs, keyword_init: true) do
      def ok? = missed_specs.empty?

      def summary
        return "[rspec_tia] 取りこぼしなし（失敗 #{failed_specs.size}件はすべて予測済み）" if ok?

        "[rspec_tia] 予測が取りこぼした失敗spec #{missed_specs.size}件:\n" +
          missed_specs.sort.map { |spec| "  - #{spec}" }.join("\n")
      end
    end

    def initialize(junit_report:, predicted_specs:)
      @junit_report = junit_report
      @predicted_specs = Set.new(predicted_specs)
    end

    def call
      failed = @junit_report.failed_files
      Result.new(
        failed_specs: failed,
        predicted_specs: @predicted_specs,
        missed_specs: failed - @predicted_specs,
      )
    end
  end
end
