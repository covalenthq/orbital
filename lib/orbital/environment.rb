require 'ostruct'
require 'pathname'
# require 'uri'
require 'set'

require 'tty-platform'

require 'orbital/errors'
# require_relative 'errors'

module Orbital; end

class Orbital::Environment
  def self.default
    self.new(
      wd: Pathname.new(Dir.pwd).expand_path,
      sdk_root: Pathname.new(__FILE__).parent.parent.parent.expand_path,
      shell_env: ENV.to_h
    )
  end

  def initialize(wd:, sdk_root:, shell_env:)
    @sdk = SDK.new(sdk_root)
    @shell = Shell.new(shell_env)
    @project = Project.detect(wd)

    @sdk.environment = self
    @shell.environment = self

    if @project
      @project.environment = self
    end

    @platform = TTY::Platform.new

    @validations_done = Set.new
  end

  attr_reader :sdk
  attr_reader :project
  attr_reader :shell
  attr_reader :platform

  def project!
    unless @project
      raise Orbital::CommandValidationError.new("command must be run within a git worktree")
    end

    @project
  end

  def validate(validation_name)
    return true if @validations_done.member?(validation_name)
    yield
    @validations_done.add(validation_name)
  end
end

class Orbital::Environment::Shell
  def initialize(env)
    @env = env
    @homedir = Pathname.new(env['HOME'])
  end

  attr_accessor :environment

  attr_reader :homedir

  def xdg_prefix
    return @xdg_prefix if @xdg_prefix

    @xdg_prefix =
      if xdg_data_home = @env['XDG_DATA_HOME']
        Pathname.new(xdg_data_home).parent
      else
        @homedir / '.local'
      end
  end

  def kubectl_config_path
    @homedir / '.kube' / 'config'
  end
end

class Orbital::Environment::SDK
  def initialize(root)
    @root = root
  end

  attr_accessor :environment

  attr_reader :root


  INSTALL_PREFIX_SIGNATURE_DIRS = %w(bin etc share var libexec)

  def installed?
    not(self.install_prefix.nil?)
  end

  def git_worktree?
    # can be a directory, or a file if `git worktree add` is used
    (@root / '.git').exist?
  end

  def worktree_clean?
    return @worktree_clean if @probed_worktree_clean
    return false unless self.git_worktree?

    @probed_worktree_clean = true
    Dir.chdir(@root.to_s) do
      @worktree_clean = `git status --porcelain`.strip.empty?
    end
  end

  def install_prefix
    return @install_prefix if @probed_install_prefix
    @probed_install_prefix = true

    maybe_prefix = @root.parent.parent

    @install_prefix =
      if INSTALL_PREFIX_SIGNATURE_DIRS.find{ |d_name| (maybe_prefix / d_name).directory? }
        maybe_prefix
      end
  end


  def state_dir
    return @state_dir if @state_dir

    @state_dir =
      if prefix = self.install_prefix
        prefix / 'var' / 'lib' / 'orbital'
      else
        @root / 'var'
      end
  end
end

class Orbital::Environment::Project
  def self.detect(wd)
    result = IO.popen(['git', 'rev-parse', '--show-toplevel'], err: [:child, :out], chdir: wd.expand_path.to_s){ |io| io.read }

    if $?.success?
      toplevel_path = Pathname.new(result.strip).expand_path
      proj = self.new(toplevel_path)
    else
      nil
    end
  end

  def initialize(root)
    @root = root
  end

  attr_accessor :environment

  attr_reader :root

  def worktree_clean?
    return @worktree_clean if @probed_worktree_clean
    @probed_worktree_clean = true
    Dir.chdir(@root.to_s) do
      @worktree_clean = `git status --porcelain`.strip.empty?
    end
  end

  def config_path
    @root / '.orbital.yaml'
  end

  def config
    return @orbital_config if @probed_orbital_config
    @probed_orbital_config = true

    @orbital_config =
      if self.config_path.file?
        YAML.load(self.config_path.read)
      end
  end

  def template_paths
    return @template_paths if @template_paths

    @template_paths =
      if conf = self.config && not(conf.nil?) && tpl_paths = conf['burn_in_template_paths']
        tpl_paths.map{ |rel_path| @root / rel_path }
      else
        []
      end
  end

  def appctl
    return @appctl if @probed_appctl
    @probed_appctl = true

    @appctl = Orbital::Environment::Appctl.detect(@root)
  end

  def appctl!
    appctl_inst = self.appctl

    unless appctl_inst
      raise Orbital::CommandValidationError.new("active project must contain an .appctlconfig")
    end

    appctl_inst
  end
end

class Orbital::Environment::Appctl
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
