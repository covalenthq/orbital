require 'pathname'

require 'orbital/errors'

module Orbital; end

class Orbital::Context
  def self.default
    self.create(
      wd: Pathname.new(Dir.pwd).expand_path,
      sdk_root: Pathname.new(__FILE__).parent.parent.parent.expand_path,
      shell_env: ENV.to_h
    )
  end

  def self.create(**kwargs)
    inst = self.new(**kwargs)
    require 'orbital/context/registry'
    Orbital::Context::Registry.instance.register(inst)
    inst
  end

  def self.lookup(uuid)
    require 'orbital/context/registry'
    Orbital::Context::Registry.instance.fetch_instance(uuid)
  end

  def initialize(wd:, sdk_root:, shell_env:, log_sink: $stderr)
    @cfg = {
      wd: Pathname.new(wd),
      sdk_root: Pathname.new(sdk_root),
      shell_env: shell_env,
      log_sink: log_sink
    }

    @validations_done = Set.new
  end

  attr_accessor :uuid

  def sdk
    return @sdk if @sdk
    require 'orbital/context/sdk'
    @sdk = Orbital::Context::SDK.new(@cfg[:sdk_root])
  end

  def shell
    return @shell if @shell
    require 'orbital/context/shell'
    @shell = Orbital::Context::Shell.new(@cfg[:shell_env])
  end

  def project
    return @project if @probed_project
    @probed_project = true
    require 'orbital/context/project'
    @project = Orbital::Context::Project.detect(@cfg[:wd])
  end

  def machine
    return @machine if @machine
    require 'orbital/context/machine'
    @machine = Orbital::Context::Machine.detect()
  end

  def task_manager
    return @task_manager if @task_manager
    require 'orbital/context/task_manager'
    @task_manager = Orbital::Context::TaskManager.new
  end

  def logger
    return @logger if @logger
    require 'orbital/logger'
    @logger = Orbital::Logger.new(sink: @cfg[:log_sink])
  end

  def project!
    proj = self.project
    unless proj
      raise Orbital::CommandValidationError.new("command must be run within a git worktree")
    end
    proj
  end

  def validate(validation_name)
    return true if @validations_done.member?(validation_name)
    yield
    @validations_done.add(validation_name)
  end

  def k8s_client
    return @k8s_client if @k8s_client
    require 'k8s-ruby'
    @k8s_client = K8s::Client.config(K8s::Config.load_file(self.shell.kubectl_config_path))
    @k8s_client.apis(prefetch_resources: true)
    @k8s_client
  end

  def k8s_resources
    return @k8s_resources if @k8s_resources
    require 'orbital/context/k8s_known_resources'
    @k8s_resources = Orbital::Context::K8sKnownResources.new(self.k8s_client)
  end

  def gcloud_client
    return @gcloud_client if @gcloud_client
    require 'orbital/converger/gcloud'
    accounts_store = self.sdk.state_dir / 'setup' / 'gcloud-service-accts'
    @gcloud_client = GCloud.new(accounts_store)
  end

  def helm_client
    return @helm_client if @helm_client
    require 'orbital/converger/helm'
    @helm_client = Helm.new
  end

  def mkcert_client
    return @mkcert_client if @mkcert_client
    require 'orbital/converger/mkcert'
    certs_store = self.sdk.state_dir / 'setup' / 'local-ca-cert'
    @mkcert_client = MkCert.new(certs_store)
  end
end
