require 'orbital/context/deploy_environment'

class Orbital::Context::DeployEnvironment::GKEEnvironment < Orbital::Context::DeployEnvironment
  def gcp_project; @config['project']; end
  def gcp_compute_zone; @config['compute']['zone']; end
  def gke_cluster_name; @config['cluster_name']; end

  def location
    [:gke, self.gcp_project, self.gcp_compute_zone, self.gke_cluster_name]
  end

  def dashboard_uri
    URI.parse("https://console.cloud.google.com/kubernetes/application/#{self.gcp_compute_zone}/#{self.gke_cluster_name}/#{self.k8s_namespace}/#{self.k8s_app_resource_name}?project=#{self.gcp_project}")
  end

  def kubectl_context_names
    ["gke_#{self.gcp_project}_#{self.gcp_compute_zone}_#{self.gke_cluster_name}"]
  end
end
