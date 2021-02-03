# frozen_string_literal: true

require 'ostruct'

require 'kustomize'

require 'orbital/command'

module Orbital; end
module Orbital::Commands; end
class Orbital::Commands::Kustomize < Orbital::Command
  def initialize(*opts)
    super(*opts)

    if @options.env.nil? and @context.project
      @options.env = @context.project.default_env_name
    end

    if app = @context.application
      app.select_deploy_environment(@options.env)
    end
  end

  def validate_environment!
    return if @context_validated

    @context.validate :has_project do
      @context.project!
    end

    @context.validate :has_appctlconfig do
      @context.application!
    end

    @context_validated = true
  end

  def execute(input: $stdin, output: $stdout)
    self.validate_environment!

    logger.step "collect release information"

    @release = OpenStruct.new
    @release.created_at = Time.now

    @context.project.proposed_release = @release

    @release.from_git_branch = `git branch --show-current`.strip
    @release.from_git_branch = nil if @release.from_git_branch.empty?
    @release.from_git_ref = `git rev-parse HEAD`.strip

    @release.artifact_refs = {}

    @release.tag = OpenStruct.new(
      name: "v#{Time.now.strftime("%Y%m%d%H%M%S")}",
      state: :not_pushed
    )

    deploy_env = @context.application.active_deploy_environment

    unless deploy_env.kustomization_dir.directory?
      logger.fatal ["kustomization directory for env '", Paint[deploy_env.name.to_s, :bold], "' does not exist"]
    end

    kustomize_emitter = Kustomize.load(deploy_env.kustomization_dir, session: @context.kustomize_session)

    hydrated_config = kustomize_emitter.to_yaml_stream

    $stdout.write(hydrated_config)
  end
end
