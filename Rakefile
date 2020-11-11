require 'pathname'
require_relative 'converger/helm'
require_relative 'converger/kubectl'
require_relative 'converger/mkcert'

wd = Pathname.new(__FILE__).parent

helm = Helm.new
k8s_resources = Kubectl.new(wd / 'resources')
k8s_local_secrets = Kubectl.new(wd / 'local-secrets')
mkcert = MkCert.new(wd / 'local-ca-cert')

task default: [:base, :infra]

task base: [:namespaces, :secrets, :certs]

task :namespaces do
  k8s_resources[:namespaces].apply_all!
end

task :secrets do
  k8s_local_secrets.apply_all!
end

task :certs do
  mkcert.ensure_cert_uploaded_to_cluster!('local-ca', namespace: :infrastructure)
end

task :infra => [:base] do
  helm.register_repos({
    'stable' => 'https://charts.helm.sh/stable',
    'ingress-nginx' => 'https://kubernetes.github.io/ingress-nginx',
    'jetstack' => 'https://charts.jetstack.io'
  })

  helm.ensure_deployed 'lb', 'ingress-nginx/ingress-nginx',
    namespace: :infrastructure

  helm.ensure_deployed 'cert-manager', 'jetstack/cert-manager',
    namespace: :infrastructure,
    version_constraint: '^1.0.3',
    config_map: {
      installCRDs: true
    }

  k8s_resources[:local_ca].apply_all!
  k8s_resources[:letsencrypt].apply_all!

  k8s_resources[:external_dns].apply_all!
end

