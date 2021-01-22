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

  def config_dir
    @root / '.orbital'
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

  def images
    return @images if @images

    imgs = self.config['images'] || []

    @images =
      imgs.map do |r|
        source_path = @root / r['source_path']
        [r['name'], source_path]
      end.to_h
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

  def inspect
    "#<Orbital/Project root=#{@root.to_s.inspect}>"
  end
end
