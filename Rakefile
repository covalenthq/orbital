require 'pathname'
require 'securerandom'
require 'k8s-ruby'
require 'tty-prompt'

require_relative 'converger/cmd_runner'
require_relative 'converger/helm'
require_relative 'converger/kubectl'
require_relative 'converger/kube_resource_manager'
require_relative 'converger/mkcert'
require_relative 'converger/gcloud'

def has_resource?(resource_set, resource_name)
  resource_set.list.find do |r|
    r.name == resource_name or r.metadata.name == resource_name
  end
end


wd = Pathname.new(__FILE__).parent
state_dir = wd / 'var'
local_resources = wd / 'resources'
k8s_config_path = Pathname.new(ENV['HOME']) / '.kube' / 'config'

k8s = K8s::Client.config(K8s::Config.load_file(k8s_config_path.to_s))
k8s.apis(prefetch_resources: true)

sh = CmdRunner.new
prompt = TTY::Prompt.new
helm = Helm.new
gcloud = GCloud.new(state_dir / 'gcloud-service-accts')
k8s_local_secrets = KubeResourceManager.new(k8s, state_dir / 'local-secrets')
k8s_infra_secrets = k8s.api('v1').resource('secrets', namespace: 'infrastructure')
mkcert = MkCert.new(state_dir / 'local-ca-cert')

toplevel_binding = binding

namespace :dev do
  desc "sets up a local development cluster"
  task :base => [
    :"cluster:namespaces",
    :"cluster:ingress-controller",
    :"dev:cluster:registry-access",
    :"dev:cluster:ca-cert",
  ]

  desc "interact with k8s resources at the REPL"
  task :console do
    require 'pry'
    toplevel_binding.pry
  end

  namespace :local do
    task :'ca-cert' => [mkcert.paths[:cert]]

    file(mkcert.paths[:cert]) do
      mkcert.ensure_cert_created!
    end

    desc "installs a DNS proxy on the host to enable DNS resolution of cluster services"
    task :'dns-proxy' do
      dnsmasq_conf_path = Pathname.new('/usr/local/etc/dnsmasq.conf')
      dnsmasq_conf_dir = Pathname.new('/usr/local/etc/dnsmasq.d')
      cluster_dns_conf_path = dnsmasq_conf_dir / 'k8s.conf'

      next if cluster_dns_conf_path.file?

      unless sh.command_available?('dnsmasq')
        sh.run_command! :brew, :install, 'dnsmasq'
      end

      dnsmasq_conf_dir.mkpath

      cluster_dns_conf_path.open('w') do |f|
        # for external cluster access
        f.puts 'no-resolv'
        f.puts 'no-poll'
        f.puts 'address=/.localhost/127.0.0.1'

        # fixes a bug with Docker on Mac's k8s
        f.puts 'address=/localhost.localdomain/127.0.0.1'
      end

      dnsmasq_conf_path.open('a') do |f|
        f.puts 'conf-dir=/usr/local/etc/dnsmasq.d/,*.conf'
      end

      sh.run_command! :sudo, :brew, :services, :restart, 'dnsmasq'

      IO.popen(['sudo', 'scutil'], 'r+') do |scutil|
        scutil.puts 'd.init'
        scutil.puts 'd.add ServerAddresses * 127.0.0.1'
        scutil.puts 'd.add SupplementalMatchDomains * k8s.localhost'
        scutil.puts "set State:/Network/Service/#{SecureRandom.uuid}/DNS"
        scutil.close
      end
    end
  end

  namespace :cluster do
    desc "generates and installs a local CA cert into the cluster for development use"
    task :'ca-cert' => [:"local:ca-cert", :namespaces] do
      next if has_resource?(k8s_infra_secrets, 'local-ca')

      local_ca_tls_secret = k8s::Resource.new(
        apiVersion: 'v1',
        kind: 'Secret',
        metadata: {
          namespace: 'infrastructure',
          name: 'local-ca'
        },
        type: 'kubernetes.io/tls',
        data: {
          'tls.crt' => Base64.encode64(ca_cert[:cert].read),
          'tls.key' => Base64.encode64(ca_cert[:key].read),
        }
      )

      K8s::Stack.new('local-ca-tls-secret', [local_ca_tls_secret]).apply(k8s)
    end

    desc "enables the cluster to pull Docker images from the Covalent gcr.io bucket"
    task :'registry-access' => [:namespaces] do
      cduser_gcp_svcacct = "cduser@covalent-project.iam.gserviceaccount.com"

      next if has_resource?(k8s_infra_secrets, 'covalent-project-gcr-auth')

      creds_path =
        gcloud.ensure_key_for_service_account!(cduser_gcp_svcacct)

      auth_doc = {
        auths: {
          "gcr.io" => {
            email: cduser_gcp_svcacct,
            username: "_json_key",
            password: creds_path.read
          }
        }
      }

      gcr_auth_secret = k8s::Resource.new(
        apiVersion: 'v1',
        kind: 'Secret',
        metadata: {
          namespace: 'infrastructure',
          name: 'covalent-project-gcr-auth'
        },
        type: 'kubernetes.io/dockerconfigjson',
        data: {
          '.dockerconfigjson' => Base64.encode64(auth_doc.to_json)
        }
      )

      K8s::Stack.new('gcr-auth-secret', [gcr_auth_secret]).apply(k8s)

      k8s.api('v1').resource('serviceaccount', namespace: 'default').merge_patch('default', {
        imagePullSecrets: [
          {namespace: 'infrastructure', name: 'covalent-project-gcr-auth'}
        ]
      })
    end
  end
end

namespace :prod do
  desc "sets up an publically-available cloud cluster"
  task :base => [
    :"cluster:namespaces",
    :"cluster:ingress-controller",
    :"prod:cluster:external-dns-sync",
  ]

  namespace :cluster do
    task :"cloudflare-api-access" => [:namespaces] do
      next if has_resource?(k8s_infra_secrets, 'cloudflare-api')

      token = prompt.mask("Cloudflare API token:") do |q|
        q.required true
        q.validate /\w+/
      end

      cloudflare_api_secret = k8s::Resource.new(
        apiVersion: 'v1',
        kind: 'Secret',
        metadata: {
          namespace: 'infrastructure',
          name: 'cloudflare-api'
        },
        type: 'Opaque',
        data: {
          'token' => Base64.strict_encode64(token)
        }
      )

      puts JSON.parse(cloudflare_api_secret.to_json()).to_yaml

      K8s::Stack.new('cloudflare-api-secret', [cloudflare_api_secret]).apply(k8s)
    end

    desc "installs an agent in the cluster to sync ingress hostnames with a DNS registrar"
    task :"external-dns-sync" => [:"cluster:namespaces", :"cloudflare-api-access"] do
      external_dns = K8s::Stack.load(
        'external-dns',
        local_resources / 'external-dns.yaml'
      )

      external_dns.apply(k8s, prune: true)
    end
  end
end

namespace :local do
  task :'helm-repos' do
    helm.register_repos({
      'stable' => 'https://charts.helm.sh/stable',
      'ingress-nginx' => 'https://kubernetes.github.io/ingress-nginx',
      'jetstack' => 'https://charts.jetstack.io'
    })
  end
end

namespace :cluster do
  task :namespaces do
    k8s_namespaces = k8s.api('v1').resource('namespaces')

    need_namespaces = %w(infrastructure production development staging)
    have_namespaces = k8s_namespaces.list.map{ |ns| ns.metadata.name }

    (need_namespaces - have_namespaces).each do |ns_name|
      ns_resource = K8s::Resource.new(
        apiVersion: 'v1',
        kind: 'Namespace',
        metadata: {
          name: ns_name
        }
      )

      k8s_namespaces.create_resource(ns_resource)
    end
  end

  desc "installs an ingress controller (and TLS cert controller) into the cluster"
  task :"ingress-controller" => [:namespaces, :"local:helm-repos"] do
    helm.ensure_deployed('lb', 'ingress-nginx/ingress-nginx',
      namespace: :infrastructure
    )

    helm.ensure_deployed('cert-manager', 'jetstack/cert-manager',
      namespace: :infrastructure,
      version_constraint: '^1.0.3',
      config_map: {
        installCRDs: true
      }
    )

    issuers = K8s::Stack.load(
      'issuers',
      local_resources / 'issuers.yaml'
    )

    issuers.apply(k8s, prune: true)
  end
end
