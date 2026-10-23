require 'rexml/document'
require 'set'

module RspecTia
  # Read JUnit XML produced by rspec_junit_formatter.
  #
  # Used for two purposes:
  #   - Estimate execution time savings by summing testcase durations per spec file.
  #   - Audit missed predictions by collecting spec files from failed testcases.
  class JunitReport
    FAILURE_ELEMENTS = %w(failure error).freeze

    class << self
      def load_dir(dir)
        paths = Dir.glob(File.join(dir, '**', '*.xml')).sort
        new(paths)
      end
    end

    def initialize(paths)
      @paths = paths
      @durations = Hash.new(0.0)
      @failed_files = Set.new
      @parsed = false
      @validation_errors = []
      @parsed_file_count = 0
    end

    def durations
      parse
      @durations
    end

    def failed_files
      parse
      @failed_files
    end

    # Metrics can use partial aggregates, but Audit must not interpret missing input as success.
    def validation_errors
      parse
      @validation_errors
    end

    def parsed_file_count
      parse
      @parsed_file_count
    end

    def empty?
      parse
      @durations.empty?
    end

    private

    def parse
      return if @parsed

      @parsed = true
      @validation_errors << 'No JUnit XML files found' if @paths.empty?
      @paths.each { |path| parse_file(path) }
    end

    def parse_file(path)
      document = REXML::Document.new(File.read(path))
      unless document.root && %w(testsuite testsuites).include?(document.root.name)
        @validation_errors << "#{path}: No JUnit testsuite/testsuites element found"
        return
      end

      # Allow valid empty suites, distinguishing them from missing or malformed XML.
      @parsed_file_count += 1
      REXML::XPath.each(document, '//testcase') do |testcase|
        file = normalize(testcase.attributes['file'])
        if file.nil?
          @validation_errors << "#{path}: A failing testcase has no file attribute" if failed?(testcase)
          next
        end

        @durations[file] += testcase.attributes['time'].to_f
        @failed_files << file if failed?(testcase)
      end
    rescue REXML::ParseException, SystemCallError => e
      # Keep processing other files if a JUnit report is truncated, for example by a job timeout.
      message = "Could not read junit.xml: #{path}: #{e.message}"
      @validation_errors << message
      warn "[rspec_tia] #{message}"
    end

    def failed?(testcase)
      testcase.elements.any? { |element| FAILURE_ELEMENTS.include?(element.name) }
    end

    # rspec_junit_formatter emits paths in the form "./spec/...".
    def normalize(file)
      return nil if file.nil? || file.strip.empty?

      file.delete_prefix('./')
    end
  end
end
