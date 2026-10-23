require 'set'

module RspecTia
  # 予測の取りこぼしを検証する。
  #
  # 全実行のjunit.xmlで落ちたspecが、同じ変更に対する予測に含まれていたかを見る。
  # 含まれていなければ、その変更は予測できていなかった＝マップか設定に穴がある。
  #
  # 予測実行を本番で使う以上、この検証を回し続けないと「静かに落とすようになった」ことに気付けない。
  class Audit
    Result = Struct.new(:failed_specs, :predicted_specs, :missed_specs, :validation_errors, keyword_init: true) do
      def ok? = Array(validation_errors).empty? && missed_specs.empty?

      def summary
        unless Array(validation_errors).empty?
          return "[rspec_tia] Cannot validate audit:\n" + validation_errors.map { |error| "  - #{error}" }.join("\n")
        end

        return "[rspec_tia] No missed failures (all #{failed_specs.size} failing specs were predicted)" if ok?

        "[rspec_tia] Prediction missed #{missed_specs.size} failing specs:\n" +
          missed_specs.sort.map { |spec| "  - #{spec}" }.join("\n")
      end
    end

    def initialize(junit_report:, predicted_specs:, full_run: false)
      @junit_report = junit_report
      @predicted_specs = Set.new(predicted_specs)
      @full_run = full_run
    end

    def call
      failed = @junit_report.failed_files
      Result.new(
        failed_specs: failed,
        predicted_specs: @predicted_specs,
        missed_specs: @full_run ? Set.new : failed - @predicted_specs,
        validation_errors: @junit_report.validation_errors,
      )
    end
  end
end
