require_relative 'lib/rspec_tia/version'

Gem::Specification.new do |spec|
  spec.name = 'rspec_tia'
  spec.version = RspecTia::VERSION
  spec.authors = ['Shinichi Maeshima']
  spec.summary = 'Test Impact Analysis for RSpec'
  spec.description = <<~DESC
    コードカバレッジからspecファイル単位の依存マップを作り、
    変更されたファイルに影響するspecだけを選び出す。
  DESC
  spec.license = 'MIT'
  spec.required_ruby_version = '>= 3.1.0'

  spec.files = Dir['lib/**/*.rb', 'exe/*', 'README.md', 'LICENSE.txt']
  spec.bindir = 'exe'
  spec.executables = %w(rspec-tia)
  spec.require_paths = %w(lib)

  spec.add_dependency 'rexml', '~> 3.2'
  spec.add_dependency 'rspec-core', '~> 3.9'

  spec.metadata['rubygems_mfa_required'] = 'true'
end
