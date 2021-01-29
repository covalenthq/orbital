# frozen_string_literal: true

ruby '>= 2.6.0'
source 'https://rubygems.org'

# Specify your gem's dependencies in orbital.gemspec
gemspec

gem 'k8s-ruby', github: 'tsutsu/k8s-ruby', branch: 'fork-master'

if ENV['GEM_UNDER_DEVELOPMENT'] == 'orbital'
  gem 'rake', '~> 13.0'
  gem 'rspec', '~> 3.10.0'
  gem 'pry', '~> 0.13.1'

  # gem 'accessory', path: '../accessory'
  # gem 'kustomizer', path: '../kustomizer'
  # gem 'kubesealr', path: '../kubesealr'
end
