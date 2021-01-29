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

  spec.add_dependency 'tty-command', '~> 0.10.0'
  spec.add_dependency 'tty-link', '~> 0.1.1'
  spec.add_dependency 'tty-which', '~> 0.4.2'
  spec.add_dependency 'tty-prompt', '~> 0.23'
  spec.add_dependency 'tty-platform', '~> 0.3.0'
  spec.add_dependency 'tty-table', '~> 0.12.0'
  spec.add_dependency 'thor', '~> 1.0.1'
  spec.add_dependency 'activesupport', '~> 6.1.1'
  spec.add_dependency 'k8s-ruby', '~> 0.10.5'
  spec.add_dependency 'paint', '~> 2.2.1'
  spec.add_dependency 'recursive-open-struct', '~> 1.0', '>= 1.0.1'
  spec.add_dependency 'accessory', '~> 0.1.10'
  spec.add_dependency 'kustomizer', '~> 0.1.6'
  spec.add_dependency 'kubesealr', '~> 0.1.0'
  spec.add_dependency 'base32-multi', '~> 0.1.0'
  # spec.add_dependency 'rugged', '~> 1.1.0'
end
