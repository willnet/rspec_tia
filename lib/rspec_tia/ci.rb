require 'rspec_tia/ci/base'
require 'rspec_tia/ci/gitlab'
require 'rspec_tia/ci/git'

module RspecTia
  module Ci
    ADAPTERS = {
      'gitlab' => Gitlab,
      'git' => Git,
    }.freeze

    # 'auto' のときは CI 固有のアダプタを優先し、無ければ git にフォールバックする
    AUTO_ORDER = %w(gitlab git).freeze

    class UnknownAdapterError < StandardError; end

    def self.build(config)
      name = config.ci_adapter
      return build_auto(config) if name == 'auto'

      klass = ADAPTERS[name]
      raise UnknownAdapterError, "未知のCIアダプタです: #{name.inspect}" if klass.nil?

      klass.new(config)
    end

    def self.build_auto(config)
      name = AUTO_ORDER.find { |candidate| ADAPTERS.fetch(candidate).available? }
      raise UnknownAdapterError, '利用できるCIアダプタがありません' if name.nil?

      ADAPTERS.fetch(name).new(config)
    end
  end
end
