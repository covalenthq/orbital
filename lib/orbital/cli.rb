# frozen_string_literal: true

require 'thor'
require 'orbital/core_ext/to_flat_string'
require 'orbital/environment'

module Orbital
  class CLI < Thor
    class_option :workdir, hide: true, required: true
    class_option :sdkroot, hide: true, required: true
    class_option :shellenv, hide: true, required: true

    def self.exit_on_failure?
      true
    end

    desc 'version', 'Print the Orbital SDK version'
    def version
      require_relative 'version'
      puts "v#{Orbital::VERSION}"
    end
    map %w(--version -v) => :version

    desc 'trigger', 'Trigger Github Actions workflows for project'
    method_option :repo, aliases: '-r', type: :string,
                         desc: "Repo to target (app, deployment, or \"username/reponame\")"
    method_option :branch, aliases: '-b', type: :string,
                           desc: "Branch of repo that workflow-runner will run in"
    method_option :workflow, aliases: '-w', type: :string, required: true,
                             desc: "Name of workflow to run"
    method_option :input, aliases: '-i', type: :array,
                          desc: "Set a workflow input (format KEY=VALUE)"
    def trigger(*)
      require_relative 'commands/trigger'
      Orbital::Commands::Trigger.new(options).execute
    end

    desc 'update', 'Update the Orbital SDK'
    def update(*)
      require_relative 'commands/update'
      Orbital::Commands::Update.new(options).execute
    end

    desc 'setup', 'Run dev-toolchain and k8s-cluster setup workflows'
    def setup(*)
      require_relative 'commands/setup'
      Orbital::Commands::Setup.new(options).execute
    end

    desc 'release', 'Burn a tagged release commit, and build an image from it'
    method_option :imagebuild, aliases: '-b', type: :string, banner: 'STRATEGY',
                               enum: ['local', 'github', 'cloudbuild'], default: 'local',
                               desc: "Build Docker image with the given strategy."
    method_option :deploy, aliases: '-d', type: :boolean,
                           desc: "Deploy to staging automatically if release succeeds."
    method_option :remote, aliases: '-r', type: :boolean, default: false,
                           desc: "Run deploy remotely using a Github Actions workflow."
    method_option :wait, aliases: '-w', type: :boolean, default: true,
                         desc: "Wait for k8s state to converge. (requires kubectl(1))"
    def release(*)
      require_relative 'commands/release'
      Orbital::Commands::Release.new(options).execute
    end

    desc 'deploy', 'Push a release to a k8s appctl(1) environment'
    method_option :tag, aliases: '-t', type: :string, required: true,
                        desc: "Release tag to deploy."
    method_option :env, aliases: '-e', type: :string, default: "staging",
                        desc: "appctl(1) environment to target."
    method_option :remote, aliases: '-r', type: :boolean, default: false,
                           desc: "Run deploy remotely using a Github Actions workflow."
    method_option :wait, aliases: '-w', type: :boolean, default: true,
                         desc: "Wait for k8s state to converge. (requires kubectl(1))"
    def deploy(*)
      require_relative 'commands/deploy'
      Orbital::Commands::Deploy.new(options).execute
    end
  end
end
