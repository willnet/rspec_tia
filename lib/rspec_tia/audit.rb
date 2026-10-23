require 'set'

module RspecTia
  # Check predictions for missed failures.
  #
  # Check whether specs that failed in a full-suite JUnit report were predicted for the same change.
  # A missing spec indicates a gap in the dependency map or configuration.
  #
  # Keep auditing full-suite runs in CI to detect failures silently omitted by selective execution.
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
