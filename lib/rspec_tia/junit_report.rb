require 'rexml/document'
require 'set'

module RspecTia
  # rspec_junit_formatter が出力した junit.xml を読む。
  #
  # 使い道は2つ。
  #   - 予測でどれだけ実行時間を削れたかの見積り（testcase の time を specファイル単位に合算）
  #   - 予測の取りこぼし検証（失敗した testcase の specファイルを集める）
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

    # Metrics は部分集計を利用できるが、Audit は入力の欠落を成功と解釈しない。
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
      @validation_errors << 'JUnit XMLが見つかりません' if @paths.empty?
      @paths.each { |path| parse_file(path) }
    end

    def parse_file(path)
      document = REXML::Document.new(File.read(path))
      unless document.root && %w(testsuite testsuites).include?(document.root.name)
        @validation_errors << "#{path}: JUnitのtestsuite/testsuitesがありません"
        return
      end

      # 正常な空suiteは許容する。XMLの不在・破損とは区別する。
      @parsed_file_count += 1
      REXML::XPath.each(document, '//testcase') do |testcase|
        file = normalize(testcase.attributes['file'])
        if file.nil?
          @validation_errors << "#{path}: file属性のない失敗testcaseがあります" if failed?(testcase)
          next
        end

        @durations[file] += testcase.attributes['time'].to_f
        @failed_files << file if failed?(testcase)
      end
    rescue REXML::ParseException, SystemCallError => e
      # 途中で切れた junit.xml（ジョブのタイムアウト等）で全体を落とさない
      message = "junit.xml を読めませんでした: #{path}: #{e.message}"
      @validation_errors << message
      warn "[rspec_tia] #{message}"
    end

    def failed?(testcase)
      testcase.elements.any? { |element| FAILURE_ELEMENTS.include?(element.name) }
    end

    # rspec_junit_formatter は "./spec/..." 形式で出力する
    def normalize(file)
      return nil if file.nil? || file.strip.empty?

      file.delete_prefix('./')
    end
  end
end
