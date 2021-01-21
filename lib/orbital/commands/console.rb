# frozen_string_literal: true

require 'pry'

require 'orbital/command'

module Orbital; end
module Orbital::Commands; end
class Orbital::Commands::Console < Orbital::Command
  def execute
    if @context.application and @context.application.deploy_environments[:staging]
      @context.application.select_deploy_environment(:staging)
    end

    if @context.application and @context.application.deploy_environments
      k8s_namespaces = @context.application.deploy_environments.values.map{ |de| de.k8s_namespace }
      @context.project.secret_manager.sealing_for_namespaces(k8s_namespaces)
    end

    Pry.start(@context.get_binding, quiet: true)
  end
end
