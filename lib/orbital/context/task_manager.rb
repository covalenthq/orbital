require 'set'

module Orbital; end
class Orbital::Context; end

class Orbital::Context::TaskManager
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

  def add_env_requirement(klass, requires:)
    @env_dependencies[klass] ||= Set.new
    @env_dependencies[klass].add(requires)
  end

  def env_requirements(klass)
    @env_dependencies[klass] || Set.new
  end

  def inspect
    "#<Orbital/TaskManager>"
  end
end
