require 'rspec_tia/version'
require 'rspec_tia/configuration'
require 'rspec_tia/context'
require 'rspec_tia/map'
require 'rspec_tia/static_mapping'
require 'rspec_tia/fallback'
require 'rspec_tia/predictor'

# Do not load these entry points here: the formatter requires rspec-core to be loaded,
# while boot must start Coverage as early as possible.
module RspecTia
  class Error < StandardError; end

  class << self
    attr_writer :config

    def config
      @config ||= Configuration.load(ENV['RSPEC_TIA_CONFIG'])
    end

    # Record the commit used to generate the map for freshness checks
    # and for investigating missed predictions.
    def commit_sha
      ENV['CI_COMMIT_SHA'] || ENV['GITHUB_SHA']
    end
  end
end
