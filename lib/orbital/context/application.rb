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

    require 'orbital/context/deploy_environment'

    envs = self.env_paths.map do |f|
      env_doc = YAML.load(f.read)
      env_doc['name'] ||= f.basename.to_s.split('.')[0..-2].join('.')
      env = Orbital::Context::DeployEnvironment.detect(env_doc)
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

  def active_deploy_environment!
    denvs = self.deploy_environments

    unless denvs
      raise Orbital::CommandValidationError.new("active application must be configured with deploy environments")
    end

    unless @active_deploy_environment_name
      raise Orbital::CommandValidationError.new("a deploy environment must be selected")
    end

    unless denvs.has_key?(@active_deploy_environment_name)
      raise Orbital::CommandValidationError.new("the selected deploy environment must exist")
    end

    denvs[@active_deploy_environment_name]
  end

  def inspect
    "#<Orbital/App #{@config.application_name}>"
  end
end
