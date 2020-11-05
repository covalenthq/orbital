require 'pathname'
require_relative 'converger/helm'
require_relative 'converger/kubectl'

wd = Pathname.new(__FILE__).parent
k8s_resources_dir = wd / 'resources'
helm_release_customizations_dir = wd / 'release_customizations'

helm = Helm.new(helm_release_customizations_dir)
k8s_resources = Kubectl.new(k8s_resources_dir)

task default: [:base, :secrets, :apps]

task :base do
  helm.register_repos({
    'stable' => 'https://kubernetes-charts.storage.googleapis.com/',
    'ingress-nginx' => 'https://kubernetes.github.io/ingress-nginx',
    'jetstack' => 'https://charts.jetstack.io'
  })

  helm.ensure_deployed 'lb', 'ingress-nginx/ingress-nginx'

  helm.ensure_deployed 'cert-manager', 'jetstack/cert-manager',
    namespace: 'cert-manager',
    version_constraint: '^1.0.3',
    config_map: {
      installCRDs: true
    }

  k8s_resources[:letsencrypt].apply_all!
end

task :secrets do
  k8s_resources[:secrets].apply_all!
end

task :redis do
  k8s_resources[:redis].apply_all!
end

task :apps do
  k8s_resources[:kuard].apply_all!

  k8s_resources[:scout].apply_all!

  k8s_resources[:pyapi].apply_all!
end
