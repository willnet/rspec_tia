require 'rspec_tia/version'
require 'rspec_tia/configuration'
require 'rspec_tia/context'
require 'rspec_tia/map'
require 'rspec_tia/static_mapping'
require 'rspec_tia/fallback'
require 'rspec_tia/predictor'

# rspec_tia/formatter は rspec-core のロード後にしか定義できないため、
# rspec_tia/boot は Coverage を最初期に起動する必要があるため、いずれもここでは読み込まない。
module RspecTia
  class Error < StandardError; end

  class << self
    attr_writer :config

    def config
      @config ||= Configuration.load(ENV['RSPEC_TIA_CONFIG'])
    end

    # マップがどのコミットで作られたかを記録しておく。鮮度の判断と、
    # 予測を外したときの追跡に使う
    def commit_sha
      ENV['CI_COMMIT_SHA'] || ENV['GITHUB_SHA']
    end
  end
end
