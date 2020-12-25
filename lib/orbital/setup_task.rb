# frozen_string_literal: true

require 'ostruct'
require 'set'
require 'singleton'

require 'k8s-ruby'

require 'orbital/command'

module Orbital; end

class Orbital::SetupTaskManager
  include Singleton

  def initialize
    @running_task_mods = Set.new
    @only_once = Set.new
    @task_dependencies = {}
    @env_dependencies = {}
  end

  def started?(task_mod)
    @running_task_mods.member?(task_mod)
  end

  def start_once(task_mod)
    return false if @running_task_mods.member?(task_mod)
    @running_task_mods.add(task_mod)
    true
  end

  def only_once(step_name)
    return if @only_once.member?(step_name)

    begin
      yield
    ensure
      @only_once.add(step_name)
    end
  end

  def add_dependent_task(klass, depends_on:)
    @task_dependencies[klass] ||= []
    deps = @task_dependencies[klass]
    unless deps.include?(depends_on)
      deps << depends_on
    end
  end

  def dependent_tasks(klass)
    @task_dependencies[klass] || []
  end

  def add_env_requirement(klass, requires:)
    @env_dependencies[klass] ||= Set.new
    @env_dependencies[klass].add(requires)
  end

  def env_requirements(klass)
    @env_dependencies[klass] || Set.new
  end
end

class Orbital::SetupTask < Orbital::Command
  def initialize(*args)
    super(*args)
    @task_manager = Orbital::SetupTaskManager.instance
    @dependent_tasks = @task_manager.dependent_tasks(self.class).map(&:new)
    @options.cluster = @options.cluster.intern
  end

  def self.dependent_on(dep_name)
    task_manager = Orbital::SetupTaskManager.instance

    if dep_name.kind_of?(Symbol)
      task_manager.add_env_requirement(self.class, requires: dep_name)
    elsif dep_name.kind_of?(Module)
      task_manager.add_dependent_task(self.class, depends_on: dep_name)
    end
  end

  def validate_environment_tree!
    @dependent_tasks.each do |dep_task|
      dep_task.validate_environment_tree!
    end

    self.validate_own_environment_base!
  end

  def ensure_printed_envdeps_step
    @manager.only_once(:print_envdeps) do
      log :step, ["ensure shell environment is sane for setup task"]
    end
  end

  def validate_own_environment_base!
    return false if @environment_validated

    env_reqs = @task_manager.env_requirements(self.class)

    if env_reqs.member?(:cluster)
      @environment.validate :has_kubeconfig do
        self.ensure_printed_envdeps_step

        if @environment.shell.kubectl_config_path.file?
          log :success, ["shell is configured with a kubectl cluster (", Paint["~/.kube/config", :bold], " is available)"]
        else
          fatal [Paint["~/.kube/config", :bold], " is not configured. Please set up a (local or remote) k8s cluster."]
        end
      end
    end

    if env_reqs.member?(:mkcert)
      @environment.validate :cmd_mkcert do
        self.ensure_printed_envdeps_step

        exec_exist! 'mkcert', ["run:\n", "  ", Paint["brew install mkcert", :bold]]
      end
    end

    if env_reqs.member?(:gcloud)
      @environment.validate :cmd_gcloud do
        self.ensure_printed_envdeps_step

        exec_exist! 'gcloud', [link_to(
          "https://cloud.google.com/sdk/docs/install",
          "install the Google Cloud SDK."
        ), '.']
      end
    end

    if env_reqs.member?(:helm)
      @environment.validate :cmd_helm do
        self.ensure_printed_envdeps_step

        exec_exist! 'helm', [link_to(
          "https://helm.sh/docs/intro/install/",
          "install Helm."
        ), '.']
      end
    end

    if env_reqs.member?(:brew)
      @environment.validate :cmd_brew do
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

    @environment_validated = true
  end

  def execute_tree(*args, **kwargs)
    return unless @task_manager.start_once(self.class)

    self.validate_environment_tree!

    @task_manager.dependent_tasks(self.class).each do |dep_task|
      dep_task.execute()
    end

    self.execute(*args, **kwargs)
  end


  def k8s_client
    return @k8s_client if @k8s_client
    require 'k8s-ruby'
    @k8s_client = K8s::Client.config(K8s::Config.load_file(@environment.shell.kubectl_config_path))
    @k8s_client.apis(prefetch_resources: true)
    @k8s_client
  end

  def gcloud_client
    return @gcloud_client if @gcloud_client
    require 'orbital/converger/gcloud'
    @gcloud_client = GCloud.new(@paths.gcloud_service_accounts)
  end

  def helm_client
    return @helm_client if @helm_client
    require 'orbital/converger/helm'
    @helm_client = Helm.new
  end

  def mkcert_client
    return @mkcert_client if @mkcert_client
    require 'orbital/converger/mkcert'
    @mkcert_client = MkCert.new(@environment.sdk.state_dir / 'setup' / 'local-ca-cert')
  end

  def cluster_namespaces
    self.k8s_client.api('v1').resource('namespaces')
  end

  def cluster_infra_secrets
    self.k8s_client.api('v1').resource('secrets', namespace: 'infrastructure')
  end

  def cluster_service_accounts
    self.k8s_client.api('v1').resource('serviceaccounts', namespace: 'default')
  end

  def has_resource?(resource_set, resource_name)
    resource_set.list(fieldSelector: "metadata.name=#{resource_name}").length > 0
  end

  def local_k8s_resources_path
    @environment.sdk.root / 'share' / 'setup' / 'resources'
  end

  def local_gcloud_service_accounts_path
    @environment.sdk.state_dir / 'setup' / 'gcloud-service-accts'
  end
end
