require 'uri'
require 'set'

module Orbital; end
class Orbital::Context; end

class Orbital::Context::DeployEnvironment
  def self.detect(config)
    case config['type']
    when nil
      raise ArgumentError, "deploy environment config must specify 'type'"
    when 'gke'
      require 'orbital/context/deploy_environment/gke_environment'
      Orbital::Context::DeployEnvironment::GKEEnvironment.new(config)
    when 'local'
      require 'orbital/context/deploy_environment/local_environment'
      Orbital::Context::DeployEnvironment::LocalEnvironment.new(config)
    else
      raise NotImplementedError, "unrecognized deploy environment type #{config['type'].inspect}"
    end
  end

  def initialize(config)
    @config = config
  end

  attr_accessor :parent_application

  def name; @config['name']; end

  def active?
    @parent_application.active_deploy_environment.equal?(self)
  end

  def k8s_namespace; @config['namespace']; end
  def k8s_app_resource_name; @parent_application.name; end

  def kustomization_dir
    return @kustomization_dir if @kustomization_dir

    target = @parent_application.k8s_resources / 'envs' / self.name
    unless target.directory?
      target = @parent_application.k8s_resources / 'base'
    end
    @kustomization_dir = target
  end

  def sealing_for_namespaces
    @config['sealing_for_namespaces']
  end

  def dashboard_uri
    nil
  end

  def kubectl_context_names
    raise NotImplementedError, "#{self.class} must implement #kubectl_context_names"
  end

  def kubectl_config
    return @kubectl_config if @kubectl_config

    @kubectl_config =
      begin
        self.try_building_kubectl_config!
      rescue => e
        if populator = @parent_application.k8s_config_file_populator
          populator.call(self)
          self.try_building_kubectl_config!
        else
          raise
        end
      end
  end

  def try_building_kubectl_config!
    cfg = @parent_application.parent_project.parent_context.global_k8s_config
    expected_ctx_names = Set.new(self.kubectl_context_names)
    raise KeyError unless matching_ctx = cfg.contexts.find{ |ctx| expected_ctx_names.member?(ctx.name) }
    cfg.attributes['current-context'] = matching_ctx.name
    cfg
  end

  def k8s_client
    return @k8s_client if @k8s_client
    require 'k8s-ruby'
    @k8s_client = K8s::Client.config(self.kubectl_config)
    @k8s_client.apis(prefetch_resources: true)
    @k8s_client
  end

  def k8s_resources
    return @k8s_resources if @k8s_resources
    require 'orbital/context/k8s_known_resources'
    @k8s_resources = Orbital::Context::K8sKnownResources.new(self.k8s_client)
    @k8s_resources.parent_deploy_environment = self
    @k8s_resources
  end

  def kubeseal_client
    return @kubeseal_client if @kubeseal_client
    require 'kubeseal'
    @kubeseal_client = Kubeseal.new(
      key_fetcher: method(:kubeseal_client_fetch_keys),
      resealer: method(:kubeseal_client_rotate)
    )
  end

  def kubeseal_client_fetch_keys(fetch_mode)
    require 'openssl'
    require 'base64'

    k8s_client = self.k8s_client

    case fetch_mode
    in :public_key
      cert_req_opts = {
        method: 'GET',
        path: '/api/v1/namespaces/kube-system/services/sealed-secrets-controller:8080/proxy/v1/cert.pem'
      }

      cert_req = k8s_client.transport.request_options.merge(cert_req_opts)
      cert_resp = k8s_client.transport.excon.request(cert_req)

      if cert_resp.status != 200
        raise KeyError, "cluster certificate missing or cluster sealer not installed"
      end

      cert_pem_str = cert_resp.body

      cluster_certificate = OpenSSL::X509::Certificate.new(cert_pem_str)
      cluster_certificate.public_key

    in :private_keys
      privkey_pem_strs =
        k8s_client.api('v1')
        .resource('secrets', namespace: 'kube-system')
        .list(fieldSelector: {'type' => 'kubernetes.io/tls'})
        .filter{ |r| r.metadata.generateName == 'sealed-secrets-key' }
        .map{ |r| Base64.decode64(r.data['tls.key']) }

      privkey_pem_strs.map{ |pem| OpenSSL::PKey::RSA.new(pem) }
    end
  end

  def kubeseal_client_rotate(wrapped_ciphertext)
    require 'openssl'
    require 'base64'

    k8s_client = self.k8s_client

    rotate_req_opts = {
      method: 'POST',
      path: '/api/v1/namespaces/kube-system/services/sealed-secrets-controller:8080/proxy/v1/rotate',
      body: wrapped_ciphertext
    }

    rotate_req = k8s_client.transport.request_options.merge(rotate_req_opts)
    rotate_resp = k8s_client.transport.excon.request(rotate_req)

    rotate_resp.body
  end

  def inspect
    klass_partname = self.class.name.split('::').last
    active_part = self.active? ? ' (active)' : ''
    "#<Orbital/#{klass_partname} #{self.name}#{active_part}>"
  end
end
