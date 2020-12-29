# frozen_string_literal: true

require 'ostruct'
require 'set'
require 'singleton'

require 'k8s-ruby'

require 'orbital/command'

module Orbital; end

class Orbital::SetupTask < Orbital::Command
  def initialize(*args)
    super(*args)
    @options.cluster = @options.cluster.intern

    @dependent_tasks = self.dependent_tasks
  end

  def resolved?
    false
  end

  def validate_environment_tree!
    @dependent_tasks.each do |dep_task|
      dep_task.validate_environment_tree!
    end

    self.validate_own_environment_base!
  end

  def environment_requirements
    deps_env_reqs = @dependent_tasks.map(&:environment_requirements)
    env_reqs.inject(@task_manager.env_requirements(self.class), &:union)
  end

  def ensure_printed_envdeps_step
    @context.task_manager.only_once(:print_envdeps) do
      logger.step ["ensure shell environment is sane for setup task"]
    end
  end

  def validate_own_environment_base!
    return false if @context_validated

    env_reqs = self.environment_requirements

    if env_reqs.member?(:cluster_access)
      @context.validate :has_kubeconfig do
        self.ensure_printed_envdeps_step

        if @context.shell.kubectl_config_path.file?
          logger.success ["shell is configured with a kubectl cluster (", Paint["~/.kube/config", :bold], " is available)"]
        else
          logger.fatal [Paint["~/.kube/config", :bold], " is not configured. Please set up a (local or remote) k8s cluster."]
        end
      end
    end

    if env_reqs.member?(:mkcert)
      @context.validate :cmd_mkcert do
        self.ensure_printed_envdeps_step

        exec_exist! 'mkcert', ["run:\n", "  ", Paint["brew install mkcert", :bold]]
      end
    end

    if env_reqs.member?(:gcloud)
      @context.validate :cmd_gcloud do
        self.ensure_printed_envdeps_step

        exec_exist! 'gcloud', [link_to(
          "https://cloud.google.com/sdk/docs/install",
          "install the Google Cloud SDK."
        ), '.']
      end
    end

    if env_reqs.member?(:helm)
      @context.validate :cmd_helm do
        self.ensure_printed_envdeps_step

        exec_exist! 'helm', [link_to(
          "https://helm.sh/docs/intro/install/",
          "install Helm."
        ), '.']
      end
    end

    if env_reqs.member?(:brew)
      @context.validate :cmd_brew do
        self.ensure_printed_envdeps_step

        exec_exist! 'brew', [link_to(
          "https://brew.sh/",
          "install Homebrew."
        ), '.']
      end
    end

    if self.respond_to?(:validate_own_environment!)
      self.validate_own_environment!
    end

    @context_validated = true
  end

  def execute_tree(*args, **kwargs)
    return unless @context.task_manager.start_once(self.class)

    return if self.resolved?

    self.validate_environment_tree!

    @context.task_manager.dependent_tasks(self.class).each do |dep_task|
      dep_task.execute()
    end

    self.execute(*args, **kwargs)
  end
end
