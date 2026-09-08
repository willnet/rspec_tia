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
    end

    def durations
      parse
      @durations
    end

    def failed_files
      parse
      @failed_files
    end

    def empty?
      parse
      @durations.empty?
    end

    private

    def parse
      return if @parsed

      @parsed = true
      @paths.each { |path| parse_file(path) }
    end

    def parse_file(path)
      document = REXML::Document.new(File.read(path))
      REXML::XPath.each(document, '//testcase') do |testcase|
        file = normalize(testcase.attributes['file'])
        next if file.nil?

        @durations[file] += testcase.attributes['time'].to_f
        @failed_files << file if failed?(testcase)
      end
    rescue REXML::ParseException => e
      # 途中で切れた junit.xml（ジョブのタイムアウト等）で全体を落とさない
      warn "[rspec_tia] junit.xml を読めませんでした: #{path}: #{e.message}"
    end

    def failed?(testcase)
      testcase.elements.any? { |element| FAILURE_ELEMENTS.include?(element.name) }
    end

    # rspec_junit_formatter は "./spec/..." 形式で出力する
    def normalize(file)
      return nil if file.nil?

      file.delete_prefix('./')
    end
  end
end
