require 'uri'
require 'yaml'

require 'recursive-open-struct'

module Orbital; end
class Orbital::Context; end

class Orbital::Context::Appctl
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

  def application_name
    @config.application_name
  end

  def k8s_resources
    @project_root / @config.config_path
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

  def deploy_environments
    return @deploy_environments if @deploy_environments
    return nil unless dwt = self.deployment_worktree

    envs_path = dwt / 'environments.yaml'

    @deploy_environments = RecursiveOpenStruct.new(
      YAML.load(envs_path.read)['envs'].map{ |e| [e['name'], e] }.to_h,
      recurse_over_arrays: true
    )
  end

  def select_deploy_environment(env_name)
    @active_deploy_environment_name = env_name.to_s.intern
  end

  def active_deploy_environment
    denvs = self.deploy_environments
    return nil unless denvs and @active_deploy_environment_name
    denvs[@active_deploy_environment_name]
  end

  def gke_app_dashboard_uri
    active_env = self.active_deploy_environment

    URI("https://console.cloud.google.com/kubernetes/application/#{active_env.compute.zone}/#{active_env.cluster_name}/#{active_env.namespace}/#{@config.application_name}?project=#{active_env.project}")
  end
end
