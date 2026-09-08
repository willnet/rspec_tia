require 'rspec_tia'
# 以下はCLIからのみ読まれる（フォーマッタ側に不要な依存を持ち込まないため、
# lib/rspec_tia.rb では読み込んでいない）
require 'rspec_tia/audit'
require 'rspec_tia/ci'
require 'rspec_tia/junit_report'
require 'rspec_tia/metrics'

require 'fileutils'
require 'tmpdir'

RSpec.configure do |config|
  config.expect_with(:rspec) { |c| c.syntax = :expect }
  config.disable_monkey_patching!
  config.order = :random
  Kernel.srand config.seed
end

module SpecSupport
  # 実在チェックが入る箇所（static_mapping / predictor）のために、
  # 一時ディレクトリに実際のファイルを置いて検証する
  def with_project(files)
    Dir.mktmpdir('rspec_tia') do |root|
      files.each do |path|
        full = File.join(root, path)
        FileUtils.mkdir_p(File.dirname(full))
        File.write(full, "# #{path}\n")
      end
      yield root
    end
  end
end

RSpec.configure { |config| config.include SpecSupport }
