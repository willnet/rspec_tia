ENV['RAILS_ENV'] = 'test'
require_relative '../config/environment'
load Rails.root.join('db/schema.rb')
# Preload the bodyless model in every mode: coverage of autoload cannot mimic AR supplementation.
Account
Account.columns
require 'rack/mock'
require_relative 'support/shared_examples'

RSpec.configure do |config|
  config.disable_monkey_patching!
  config.before(:suite) { SuiteBefore.call }
  config.after(:suite) { SuiteAfter.call }
  config.before do
    # Raw SQL deliberately avoids attributing the model to unrelated specs during data reset.
    connection = ActiveRecord::Base.connection
    connection.execute('DELETE FROM accounts')
    connection.execute("INSERT INTO accounts (name) VALUES ('Ada')")
  end
end
