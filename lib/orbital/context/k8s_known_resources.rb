require 'k8s-ruby'

module Orbital; end
class Orbital::Context; end

class Orbital::Context::K8sKnownResources
  def initialize(k8s_client)
    @k8s_client = k8s_client
  end

  module ResourceSetHelpers
    def has_resource?(resource_name)
      self.list(fieldSelector: "metadata.name=#{resource_name}").length > 0
    end
  end

  def namespaces
    @k8s_client.api('v1').resource('namespaces').extend(ResourceSetHelpers)
  end

  def service_accounts
    @k8s_client.api('v1').resource('serviceaccounts', namespace: 'default').extend(ResourceSetHelpers)
  end

  def infra_secrets
    @k8s_client.api('v1').resource('secrets', namespace: 'infrastructure').extend(ResourceSetHelpers)
  end
end
