# frozen_string_literal: true

require 'thor'

module Orbital
  # Handle the application command line parsing
  # and the dispatch to various command objects
  #
  # @api public
  class CLI < Thor
    # Error raised by this runner
    Error = Class.new(StandardError)

    desc 'version', 'orbital version'
    def version
      require_relative 'version'
      puts "v#{Orbital::VERSION}"
    end
    map %w(--version -v) => :version

    desc 'setup', 'Run dev-toolchain and k8s-cluster setup workflows'
    method_option :help, aliases: '-h', type: :boolean,
                         desc: 'Display usage information'
    def setup(*)
      if options[:help]
        invoke :help, ['setup']
      else
        require_relative 'commands/setup'
        Orbital::Commands::Setup.new(options).execute
      end
    end

    desc 'release', 'Burn a tagged release commit, and build an image from it'
    method_option :help, aliases: '-h', type: :boolean,
                         desc: 'Display usage information'
    def release(*)
      if options[:help]
        invoke :help, ['release']
      else
        require_relative 'commands/release'
        Orbital::Commands::Release.new(options).execute
      end
    end

    desc 'deploy', 'Push a release to a k8s appctl(1) environment'
    method_option :help, aliases: '-h', type: :boolean,
                         desc: 'Display usage information'
    def deploy(*)
      if options[:help]
        invoke :help, ['deploy']
      else
        require_relative 'commands/deploy'
        Orbital::Commands::Deploy.new(options).execute
      end
    end
  end
end
