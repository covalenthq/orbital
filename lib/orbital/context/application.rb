require 'uri'
require 'yaml'

require 'recursive-open-struct'

module Orbital; end
class Orbital::Context; end

class Orbital::Context::Application
  def self.detect(project_root)
    appctl_config_path = project_root / '.appctlconfig'
    if appctl_config_path.file?
      self.new(project_root, YAML.load(appctl_config_path.read))
    else
      nil
    end
  end

  def initialize(project_root, appctl_config)
    @project_root = project_root
    @config = RecursiveOpenStruct.new(appctl_config, recurse_over_arrays: true)
  end

  attr_accessor :parent_project

  def name
    @config.application_name
  end

  def k8s_resources
    @project_root / @config.config_path
  end

  def env_paths
    (@project_root / @config.delivery_path / 'envs')
    .children
    .filter{ |f| f.file? and f.basename.to_s[0] != '.' }
  end

  def k8s_resource(subpath)
    RecursiveOpenStruct.new(YAML.load((self.k8s_resources / subpath).read), recurse_over_arrays: true)
  end

  def deployment_worktree_root
    @project_root / @config.deploy_repo_path
  end

  def deployment_worktree
    return @deployment_worktree if @deployment_worktree

    dwr = self.deployment_worktree_root

    if dwr.directory?
      @deployment_worktree = dwr
    end
  end

  def app_repo
    return @app_repo if @app_repo

    @app_repo = RecursiveOpenStruct.new({
      uri: URI(@config.app_repo_url),
      default_branch: "master"
    })
  end

  def deployment_repo
    return @deployment_repo if @deployment_repo

    repo_uri = URI(@config.deployment_repo_url)
    clone_uri = "git@#{repo_uri.hostname}:#{repo_uri.path[1..-1]}.git"

    @deployment_repo = RecursiveOpenStruct.new({
      uri: repo_uri,
      clone_uri: clone_uri,
      default_branch: "#{@config.application_name}-environment"
    })
  end

  attr_accessor :k8s_config_file_populator

  def deploy_environments
    return @deploy_environments if @deploy_environments

    envs = self.env_paths.map do |f|
      env_doc = YAML.load(f.read)
      env_doc['name'] ||= f.basename.to_s.split('.')[0..-2].join('.')
      env = Orbital::Context::Application::DeployEnvironment.new(env_doc)
      env.parent_application = self
      env
    end

    @deploy_environments = envs.map{ |env| [env.name.intern, env] }.to_h
  end

  def select_deploy_environment(env_name)
    @active_deploy_environment_name = env_name.to_s.intern
  end

  def active_deploy_environment
    denvs = self.deploy_environments
    return nil unless denvs and @active_deploy_environment_name
    denvs[@active_deploy_environment_name]
  end

  def inspect
    "#<Orbital/App #{@config.application_name}>"
  end
end

class Orbital::Context::Application::DeployEnvironment
  def initialize(config)
    @config = config
  end

  attr_accessor :parent_application

  def name; @config['name']; end

  def active?
    @parent_application.active_deploy_environment.equal?(self)
  end

  def gcp_project; @config['project']; end
  def gcp_compute_zone; @config['compute']['zone']; end
  def gke_cluster_name; @config['cluster_name']; end

  def k8s_namespace; @config['namespace']; end
  def k8s_app_resource_name; @parent_application.name; end

  def gke_app_dashboard_uri
    URI("https://console.cloud.google.com/kubernetes/application/#{self.gcp_compute_zone}/#{self.gke_cluster_name}/#{self.k8s_namespace}/#{self.k8s_app_resource_name}?project=#{self.gcp_project}")
  end

  def kubectl_context_name
    "gke_#{self.gcp_project}_#{self.gcp_compute_zone}_#{self.gke_cluster_name}"
  end

  def kubectl_config
    return @kubectl_config if @kubectl_config

    @kubectl_config =
      begin
        self.try_building_kubectl_config!
      rescue => e
        if populator = @parent_application.k8s_config_file_populator
          populator.call(self)
          self.try_building_kubectl_config!
        else
          raise
        end
      end
  end

  def try_building_kubectl_config!
    cfg = @parent_application.parent_project.parent_context.global_k8s_config
    expected_ctx_name = self.kubectl_context_name
    raise KeyError unless cfg.contexts.find{ |ctx| ctx.name == expected_ctx_name }
    cfg.attributes['current-context'] = expected_ctx_name
    cfg
  end

  def k8s_client
    return @k8s_client if @k8s_client
    require 'k8s-ruby'
    @k8s_client = K8s::Client.config(self.kubectl_config)
    @k8s_client.apis(prefetch_resources: true)
    @k8s_client
  end

  def k8s_resources
    return @k8s_resources if @k8s_resources
    require 'orbital/context/k8s_known_resources'
    @k8s_resources = Orbital::Context::K8sKnownResources.new(self.k8s_client)
    @k8s_resources.parent_deploy_environment = self
    @k8s_resources
  end

  def inspect
    "#<Orbital/DeployEnvironment name=#{self.name.inspect} active=#{self.active?}>"
  end
end