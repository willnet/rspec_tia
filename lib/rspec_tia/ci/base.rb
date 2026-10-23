module RspecTia
  module Ci
    # CIアダプタのインターフェース。
    # Predictor から下はCI非依存にするため、CI固有の事情は全てここより下に閉じ込める。
    class Base
      class UnsupportedError < StandardError; end

      def initialize(config)
        @config = config
      end

      def self.available?
        false
      end

      # 予測の入力をまとめて返す
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

      # マップの断片を dest_dir にダウンロードし、保存したパスの配列を返す
      def fetch_map_fragments(_dest_dir)
        raise UnsupportedError, "#{self.class.name} does not support map fetching"
      end
    end
  end
end
