require 'pathname'
require 'yaml'

require 'orbital/errors'

module Orbital; end
class Orbital::Context; end

class Orbital::Context::Project
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

  attr_accessor :parent_context

  attr_accessor :environment

  attr_reader :root

  def worktree_clean?
    return @worktree_clean if @probed_worktree_clean
    @probed_worktree_clean = true
    Dir.chdir(@root.to_s) do
      @worktree_clean = `git status --porcelain`.strip.empty?
    end
  end

  CONFIG_DIR_PATHS = ['.orbital', 'orbital']

  def config_dir
    return @config_dir if @config_dir

    maybe_config_dir =
      CONFIG_DIR_PATHS
      .map{ |dname| @root / dname }
      .find{ |d| d.directory? }

    if maybe_config_dir
      @config_dir = maybe_config_dir
    else
      @root / CONFIG_DIR_PATHS.first
    end
  end

  def managed_secrets_store_path
    self.config_dir / 'managed-secrets'
  end

  def secret_manager
    return @secret_manager if @secret_manager
    require 'orbital/secret_manager'

    sealer_from_context = lambda do
      de = self.parent_context.deploy_environment!
      de.kubeseal_client
    end

    @secret_manager =
      Orbital::SecretManager.new(
        store_path: self.managed_secrets_store_path,
        get_sealer_fn: sealer_from_context
      )
  end

  def config_path
    self.config_dir / 'project.yaml'
  end

  def config
    return @orbital_config if @orbital_config

    @orbital_config =
      if self.config_path.file?
        YAML.load(self.config_path.read)
      else
        {}
      end
  end

  def schema_version
    self.config['schema_version'] || 0
  end

  VALID_BUILD_STEP_BUILDER_KEYS = [
    'docker_image'
  ]

  def build_steps
    return @build_steps if @build_steps

    steps = self.config['build_steps'] || []

    @build_steps = steps.map do |step|
      step_builder_key = VALID_BUILD_STEP_BUILDER_KEYS.find{ |k| step.has_key?(k) }

      unless step_builder_key
        raise NotImplementedError, "unsupported build step type for #{step.inspect}"
      end

      step_type = step_builder_key.intern
      step_name = step['name'] || step_builder_key.tr('_', ' ').capitalize

      step_params = step[step_builder_key].map do |k, v|
        if /_path$/.match?(k)
          v = @root / v
        end
        [k.intern, v]
      end.to_h

      {name: step_name, builder: step_type, params: step_params}
    end
  end

  def template_paths
    return @template_paths if @template_paths

    @template_paths =
      if tpl_paths = self.config['burn_in_template_paths']
        tpl_paths.map{ |rel_path| @root / rel_path }
      else
        []
      end
  end

  def application
    return @application if @probed_application
    @probed_application = true

    require 'orbital/context/application'
    @application = Orbital::Context::Application.detect(@root)
    @application.parent_project = self if @application
    @application
  end

  def application!
    app_inst = self.application

    unless app_inst
      raise Orbital::CommandValidationError.new("active project must contain an .appctlconfig")
    end

    app_inst
  end

  attr_accessor :proposed_release

  def inspect
    "#<Orbital/Project root=#{@root.to_s.inspect}>"
  end
end
