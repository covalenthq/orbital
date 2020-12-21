# frozen_string_literal: true

require_relative 'lib/orbital/version'

Gem::Specification.new do |spec|
  spec.name          = 'orbital'
  spec.license       = 'MIT'
  spec.version       = Orbital::VERSION
  spec.authors       = ['Levi Aul']
  spec.email         = ['levi@leviaul.com']

  spec.summary       = %q{Covalent's k8s infra manager}
  spec.homepage      = 'https://github.com/covalenthq/orbital'
  spec.required_ruby_version = Gem::Requirement.new('>= 2.6.0')

  spec.metadata['homepage_uri'] = spec.homepage
  spec.metadata['source_code_uri'] = spec.homepage

  # will never be released as a gem, so we can save startup time by not
  # doing any detection here
  spec.files         = []

  spec.bindir        = 'exe'
  spec.executables   = ['orbital']
  spec.require_paths = ['lib']

  spec.add_runtime_dependency 'rake', '~> 13.0'
  spec.add_runtime_dependency 'tty-command', '~> 0.10.0'
  spec.add_runtime_dependency 'tty-link', '~> 0.1.1'
  spec.add_runtime_dependency 'tty-which', '~> 0.4.2'
  spec.add_runtime_dependency 'thor'
  spec.add_runtime_dependency 'activesupport'
  spec.add_runtime_dependency 'k8s-ruby'
  spec.add_runtime_dependency 'toml'
  spec.add_runtime_dependency 'paint'

  spec.add_development_dependency 'rspec', '~> 3.10.0'
  spec.add_development_dependency 'pry'
end
