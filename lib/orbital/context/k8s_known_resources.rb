require 'k8s-ruby'

module Orbital; end
class Orbital::Context; end

class Orbital::Context::K8sKnownResources
  def initialize(k8s_client)
    @k8s_client = k8s_client
  end

  attr_accessor :parent_deploy_environment

  def app_namespace_or(default_ns)
    return default_ns unless @parent_deploy_environment
    @parent_deploy_environment.k8s_namespace
  end

  def app_resource_name_or(default_resource_name)
    return default_resource_name unless @parent_deploy_environment
    @parent_deploy_environment.k8s_app_resource_name
  end

  def namespaces
    @k8s_client.api('v1').resource('namespaces')
  end

  def ensure_app_namespace!
    raise ArgumentError unless app_ns_name = @parent_deploy_environment.k8s_namespace
    ns_rsc = self.namespaces

    return false if ns_rsc.get(app_ns_name)

    app_ns_rc = K8s::Resource.new(
      apiVersion: 'v1',
      kind: 'Namespace',
      metadata: {
        name: app_ns_name
      }
    )

    ns_rsc.create_resource(app_ns_rc)

    true
  end

  def crds
    @k8s_client.api('apiextensions.k8s.io/v1').resource('customresourcedefinitions')
  end

  def service_accounts
    @k8s_client.api('v1').resource('serviceaccounts', namespace: app_namespace_or('default'))
  end

  def secrets
    @k8s_client.api('v1').resource('secrets', namespace: app_namespace_or('infrastructure'))
  end

  def releasetracks
    @k8s_client.api('app.gke.io/v1beta1').resource('releasetracks', namespace: app_namespace_or('default'))
  end

  def infra_secrets
    @k8s_client.api('v1').resource('secrets', namespace: 'infrastructure')
  end
end
