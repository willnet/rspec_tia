require_relative 'lib/rspec_tia/version'

Gem::Specification.new do |spec|
  spec.name = 'rspec_tia'
  spec.version = RspecTia::VERSION
  spec.authors = ['Shinichi Maeshima']
  spec.summary = 'Test Impact Analysis for RSpec'
  spec.description = <<~DESC
    Build a spec-file dependency map from code coverage and select
    only the specs affected by changed files.
  DESC
  spec.license = 'MIT'
  spec.required_ruby_version = '>= 3.3.0'

  spec.files = Dir['lib/**/*.rb', 'exe/*', 'README.md', 'LICENSE.txt']
  spec.bindir = 'exe'
  spec.executables = %w(rspec-tia)
  spec.require_paths = %w(lib)

  spec.add_dependency 'rubyzip', '~> 3.0'
  spec.add_dependency 'rexml', '~> 3.2'
  spec.add_dependency 'rspec-core', '~> 3.9'

  spec.metadata['rubygems_mfa_required'] = 'true'
end
