require 'set'

module RspecTia
  # Rails 固有の補完。
  #
  # 次のようなクラスはロード後に実行される行を持たないため、カバレッジには決して現れない。
  #
  #   class Account < ApplicationRecord
  #     belongs_to :user
  #   end
  #
  # ActiveRecord の通知から「そのspecが触ったモデル」を拾い、
  # Module.const_source_location で定義ファイルに変換して依存に足す。
  #
  # 実Railsアプリケーションの実測では、この補完によって依存エッジが 402 -> 594（+48%）に増えた。
  # 補完がないと約1/3の依存を取りこぼす。
  class RailsSupport
    # payload[:name] は "User Load" / "User Create" のような形式。
    # モデル名でないもの（SCHEMA / TRANSACTION 等）は const_source_location 側で落ちる
    SQL_EVENT = 'sql.active_record'.freeze
    INSTANTIATION_EVENT = 'instantiation.active_record'.freeze

    def self.available?
      defined?(::ActiveSupport::Notifications) ? true : false
    end

    def initialize(root:)
      @root = root.end_with?('/') ? root : "#{root}/"
      @files = Set.new
      @source_location_cache = {}
    end

    def subscribe
      ::ActiveSupport::Notifications.subscribe(INSTANTIATION_EVENT) do |*, payload|
        record(payload[:class_name])
      end
      ::ActiveSupport::Notifications.subscribe(SQL_EVENT) do |*, payload|
        record(payload[:name].to_s.split(' ').first)
      end
      self
    end

    # 直前の flush 以降に触れたファイルを返し、蓄積をリセットする
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

    # 同じクラス名が1つのspecで何百回も通知されるため、解決結果を必ずキャッシュする
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
      # 定数として解決できない名前（SQL / SCHEMA 等）は補完対象ではない
      nil
    end
  end
end
