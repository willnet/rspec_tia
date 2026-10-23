module RspecTia
  module Ci
    # CI adapter interface.
    # Keep CI-specific details behind this interface so Predictor and downstream logic stay CI-independent.
    class Base
      class UnsupportedError < StandardError; end

      def initialize(config)
        @config = config
      end

      def self.available?
        false
      end

      # Collect inputs for prediction.
      def context
        Context.new(
          changed_files: changed_files,
          labels: labels,
          commit_message: commit_message,
          merge_request: merge_request?,
        )
      end

      def changed_files = raise(NotImplementedError)
      def merge_request? = raise(NotImplementedError)
      def labels = []
      def commit_message = nil

      # Download map fragments to dest_dir and return their paths.
      def fetch_map_fragments(_dest_dir)
        raise UnsupportedError, "#{self.class.name} does not support map fetching"
      end
    end
  end
end
