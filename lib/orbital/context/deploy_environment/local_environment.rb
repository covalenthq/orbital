require 'orbital/context/deploy_environment'

class Orbital::Context::DeployEnvironment::LocalEnvironment < Orbital::Context::DeployEnvironment
  def location
    :local
  end

  LOCAL_CONTEXT_NAMES = [
    'docker-desktop'
  ].freeze

  def kubectl_context_names
    LOCAL_CONTEXT_NAMES
  end
end
