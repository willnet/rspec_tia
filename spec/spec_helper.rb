require 'rspec_tia'
# Load these dependencies only for the CLI; lib/rspec_tia.rb omits them
# to avoid introducing unnecessary dependencies into the formatter.
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
  # Create real files in a temporary directory for code that checks file existence,
  # such as static mappings and prediction.
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
