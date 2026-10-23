require_relative 'boot'
require 'rails'
require 'active_record/railtie'
require 'action_controller/railtie'
require 'action_view/railtie'
require 'logger'

module MappingFixture
  class Application < Rails::Application
    config.load_defaults 7.2
    config.root = File.expand_path('..', __dir__)
    config.eager_load = ENV.fetch('FIXTURE_EAGER_LOAD', 'false') == 'true'
    config.secret_key_base = 'mapping-fixture-secret-key-base'
    config.logger = Logger.new(File::NULL)
    config.hosts = []
  end
end
