require 'pathname'

require_relative 'converger/helm'
require_relative 'converger/kubectl'
require_relative 'converger/kube_resource_manager'
require_relative 'converger/mkcert'
require_relative 'converger/gcloud'

SVC_ACCT_CDUSER = "cduser@covalent-project.iam.gserviceaccount.com"

wd = Pathname.new(__FILE__).parent

k8s = Kubectl.new
helm = Helm.new
gcloud = GCloud.new(wd / 'gcloud-service-accts')
k8s_resources = KubeResourceManager.new(wd / 'resources')
k8s_local_secrets = KubeResourceManager.new(wd / 'local-secrets')
mkcert = MkCert.new(wd / 'local-ca-cert')

task default: [:base, :infra]

task base: [:namespaces, :secrets, :certs, :registry]

task :namespaces do
  k8s_resources[:namespaces].apply_all!
end

task :secrets do
  k8s_local_secrets.apply_all!
end

task :certs do
  ca_cert = mkcert.ensure_cert_created!

  k8s.ensure_secret!(:tls, 'local-ca',
    namespace: :infrastructure,
    cert: ca_cert[:cert],
    key: ca_cert[:key]
  )
end

task :registry do
  creds_path =
    gcloud.ensure_key_for_service_account!(SVC_ACCT_CDUSER)

  k8s.ensure_secret!(:"docker-registry", 'covalent-project-gcr-auth',
    namespace: :infrastructure,
    docker_server: 'gcr.io',
    docker_email: SVC_ACCT_CDUSER,
    docker_username: '_json_key',
    docker_password: creds_path.read,
  )

  k8s.patch!(:serviceaccount, :default, {
    imagePullSecrets: [
      {namespace: :infrastructure, name: 'covalent-project-gcr-auth'}
    ]
  })
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

  k8s_resources[:issuer].apply_all!
end

task :"external-dns" do
  k8s_local_secrets.create_as(:"Opaque", :infrastructure, 'cloudflare-api') do
    require 'tty-prompt'
    prompt = TTY::Prompt.new

    token = prompt.mask("Cloudflare API token:") do |q|
      q.required true
      q.validate /\w+/
    end

    {token: token}
  end

  k8s_local_secrets[:cloudflare_api].apply_all!

  k8s_resources[:external_dns].apply_all!
end
