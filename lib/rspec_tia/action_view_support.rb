require 'set'

module RspecTia
  # Supplement coverage with files reported by each render, including compiled templates.
  class ActionViewSupport
    # The per-template event includes partial layouts; collection events also fire on cache hits.
    EVENTS = %w[
      render_template.action_view
      render_partial.action_view
      render_collection.action_view
      render_layout.action_view
      !render_template.action_view
    ].freeze

    def self.available?
      defined?(::ActiveSupport::Notifications) ? true : false
    end

    def initialize(root:)
      @root = "#{File.expand_path(root).delete_suffix('/')}/"
      @real_root = "#{File.realpath(root).delete_suffix('/')}/"
      @files = Set.new
      @subscriptions = []
    end

    def subscribe
      return self unless @subscriptions.empty?

      EVENTS.each do |event|
        @subscriptions << ::ActiveSupport::Notifications.subscribe(event) do |*, payload|
          @files.merge(project_files(payload[:identifier]))
        end
      end
      self
    end

    def unsubscribe
      @subscriptions.each { |token| ::ActiveSupport::Notifications.unsubscribe(token) }
      @subscriptions.clear
      @files.clear
    end

    def flush
      files = @files.to_a
      @files.clear
      files
    end

    private

    def project_files(identifier)
      # Layout payloads may be virtual names; only identifier contains a resolved path.
      return [] unless identifier.is_a?(String) && File.absolute_path?(identifier)

      path = File.expand_path(identifier)
      return [] unless path.start_with?(@root) && File.file?(path)
      real_path = File.realpath(path)
      return [] unless real_path.start_with?(@real_root)

      # Changes to either a symlink or its target must select this render's consumer.
      [path.delete_prefix(@root), real_path.delete_prefix(@real_root)]
    rescue ArgumentError, SystemCallError
      # Inline/virtual templates, removed files and external engines are not project files.
      []
    end
  end
end
