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
