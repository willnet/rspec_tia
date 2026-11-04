require 'set'

module RspecTia
  # Rails-specific dependency supplementation.
  #
  # Classes like this have no lines executed after loading, so runtime usage is invisible to coverage.
  #
  #   class Account < ApplicationRecord
  #     belongs_to :user
  #   end
  #
  # Use ActiveRecord notifications to identify models touched by each spec,
  # then resolve definition files with Module.const_source_location and add dependencies.
  #
  # In one Rails application, this increased dependency edges from 402 to 594 (+48%).
  # Without supplementation, roughly one third of those dependencies were missed.
  class RailsSupport
    # payload[:name] has a form such as "User Load" or "User Create".
    # Non-model names such as SCHEMA and TRANSACTION are rejected during constant source resolution.
    SQL_EVENT = 'sql.active_record'.freeze
    INSTANTIATION_EVENT = 'instantiation.active_record'.freeze

    def self.available?
      defined?(::ActiveSupport::Notifications) ? true : false
    end

    def initialize(root:)
      @root = root.end_with?('/') ? root : "#{root}/"
      @files = Set.new
      @source_location_cache = {}
      @subscriptions = []
    end

    def subscribe
      return self unless @subscriptions.empty?

      @subscriptions << ::ActiveSupport::Notifications.subscribe(INSTANTIATION_EVENT) do |*, payload|
        record(payload[:class_name])
      end
      @subscriptions << ::ActiveSupport::Notifications.subscribe(SQL_EVENT) do |*, payload|
        record(payload[:name].to_s.split(' ').first)
      end
      self
    end

    def unsubscribe
      @subscriptions.each { |token| ::ActiveSupport::Notifications.unsubscribe(token) }
      @subscriptions.clear
      @files.clear
    end

    # Return files touched since the previous flush and reset the accumulated set.
    def flush
      files = @files.to_a
      @files = Set.new
      files
    end

    private

    def record(class_name)
      return if class_name.nil? || class_name.empty?

      path = source_location_of(class_name)
      @files << path unless path.nil?
    end

    # Cache resolution results because the same class may be reported hundreds of times per spec.
    def source_location_of(class_name)
      return @source_location_cache[class_name] if @source_location_cache.key?(class_name)

      @source_location_cache[class_name] = resolve(class_name)
    end

    def resolve(class_name)
      location = Module.const_source_location(class_name)
      path = location&.first
      return nil if path.nil? || !path.start_with?(@root)

      path.delete_prefix(@root)
    rescue NameError
      # Names that cannot be resolved as constants, such as SQL and SCHEMA, are not model dependencies.
      nil
    end
  end
end
