
require 'pathname'
require 'securerandom'
require 'ostruct'
require 'rake'

require 'tty-prompt'
require 'k8s-ruby'
require 'orbital/ext/k8s-ruby/resource_client_helpers'

require 'orbital/converger/helm'
require 'orbital/converger/kubectl'
require 'orbital/converger/kube_resource_manager'
require 'orbital/converger/mkcert'
require 'orbital/converger/gcloud'

module Orbital; end
class Orbital::Converger < Rake::Application
  def initialize(command)
    super()

    @command = command

    @paths = OpenStruct.new

    @paths.homedir = Pathname.new(ENV['HOME'])
    @paths.k8s_config = @paths.homedir / '.kube' / 'config'

    @paths.project_root = project_root
    @paths.sdk_root = sdk_root
    @paths.state_dir = @paths.sdk_root / 'var'
    @paths.local_resources = @paths.sdk_root / 'share' / 'resources'


    @prompt = TTY::Prompt.new

    @runners = OpenStruct.new
    @runners.k8s = K8s::Client.config(K8s::Config.load_file(@paths.k8s_config))
    @runners.sh = CmdRunner.new
    @runners.helm = Helm.new
    @runners.gcloud = GCloud.new(@paths.state_dir / 'gcloud-service-accts')
    @runners.mkcert = MkCert.new(@paths.state_dir / 'local-ca-cert')

    @local_resources = OpenStruct.new
    @local_resources.secrets = KubeResourceManager.new(@runners.k8s, @paths.state_dir / 'local-secrets')

    @remote_resources = OpenStruct.new
    @remote_resources.namespaces = @runners.k8s.api('v1').resource('namespaces')
    @remote_resources.service_accounts = @runners.k8s.api('v1').resource('serviceaccounts', namespace: 'default')
    @remote_resources.infra_secrets = @runners.k8s.api('v1').resource('secrets', namespace: 'infrastructure')
  end

  def ensure_namespaces(needed_namespaces)
    have_namespaces = @remote_resources.namespaces.list.map{ |ns| ns.metadata.name }

    (needed_namespaces - have_namespaces).each do |ns_name|
      ns_resource = K8s::Resource.new(
        apiVersion: 'v1',
        kind: 'Namespace',
        metadata: {
          name: ns_name
        }
      )

      @remote_resources.namespaces.create_resource(ns_resource)
    end
  end

  def add_orbital_tasks
    @last_description = "sets up a local development cluster"
    define_task(Rake::Task, 'dev:base' => [
      'dev:cluster:namespaces',
      'dev:cluster:ingress-controller',
      'dev:cluster:registry-access',
    ])

    define_task(Rake::Task, 'dev:local:ca-cert' => [
      @runners.mkcert.paths[:cert]
    ])

    define_task(Rake::FileTask, @runners.mkcert.paths[:cert]) do
      @runners.mkcert.ensure_cert_created!
    end

    @last_description = "installs a DNS proxy on the host to enable DNS resolution of cluster services"
    define_task(Rake::Task, 'dev:local:dns-proxy') do
      dnsmasq_conf_path = Pathname.new('/usr/local/etc/dnsmasq.conf')
      dnsmasq_conf_dir = Pathname.new('/usr/local/etc/dnsmasq.d')
      cluster_dns_conf_path = dnsmasq_conf_dir / 'k8s.conf'

      next if cluster_dns_conf_path.file?

      unless @runners.sh.command_available?('dnsmasq')
        @runners.sh.run_command! :brew, :install, 'dnsmasq'
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

      @runners.sh.run_command! :sudo, :brew, :services, :restart, 'dnsmasq'

      IO.popen(['sudo', 'scutil'], 'r+') do |scutil|
        scutil.puts 'd.init'
        scutil.puts 'd.add ServerAddresses * 127.0.0.1'
        scutil.puts 'd.add SupplementalMatchDomains * k8s.localhost'
        scutil.puts "set State:/Network/Service/#{SecureRandom.uuid}/DNS"
        scutil.close
      end
    end

    @last_description = "installs nginx + internal cert issuers into the cluster"
    define_task(Rake::Task, "dev:cluster:ingress-controller" => ["dev:cluster:ca-cert", "cluster:ingress-controller"]) do
      issuers = K8s::Stack.load(
        'issuers',
        local_resources / 'issuers.dev.yaml'
      )

      issuers.apply(@runners.k8s, prune: true)
    end

    @last_description = "generates and installs a local CA cert into the cluster for development use"
    define_task(Rake::Task, 'dev:cluster:ca-cert' => ["local:ca-cert", 'cluster:namespaces']) do
      next if @remote_resources.infra_secrets.member?('local-ca')

      local_ca_tls_secret = K8s::Resource.new(
        apiVersion: 'v1',
        kind: 'Secret',
        metadata: {
          namespace: 'default',
          name: 'local-ca'
        },
        type: 'kubernetes.io/tls',
        data: {
          'tls.crt' => Base64.encode64(@runners.mkcert.paths[:cert].read),
          'tls.key' => Base64.encode64(@runners.mkcert.paths[:key].read),
        }
      )

      K8s::Stack.new('local-ca-tls-secret', [local_ca_tls_secret]).apply(@runners.k8s)
    end

    @last_description = "enables the cluster to pull Docker images from the Covalent gcr.io bucket"
    define_task(Rake::Task, 'dev:cluster:registry-access' => ['cluster:namespaces']) do
      cduser_gcp_svcacct = "cduser@covalent-project.iam.gserviceaccount.com"

      next if @remote_resources.infra_secrets.member?('covalent-project-gcr-auth')

      creds_path =
        @runners.gcloud.ensure_key_for_service_account!(cduser_gcp_svcacct)

      auth_doc = {
        auths: {
          "gcr.io" => {
            email: cduser_gcp_svcacct,
            username: "_json_key",
            password: creds_path.read
          }
        }
      }

      gcr_auth_secret = K8s::Resource.new(
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

      @remote_resources.service_accounts.merge_patch('default', {
        imagePullSecrets: [
          {namespace: 'infrastructure', name: 'covalent-project-gcr-auth'}
        ]
      })
    end

    define_task(Rake::Task, 'cluster:namespaces') do
      ensure_namespaces(["infrastructure", "staging", "production"])
    end

    @last_description = "sets up an publically-available cloud cluster"
    define_task(Rake::Task, 'prod:base' => [
      :"cluster:namespaces",
      :"prod:cluster:ingress-controller",
      :"prod:cluster:external-dns-sync",
    ])

    @last_description = "installs nginx + external cert issuers into the cluster"
    define_task(Rake::Task, "prod:cluster:ingress-controller" => ["cluster:ingress-controller"]) do
      issuers = K8s::Stack.load(
        'issuers',
        @paths.local_resources / 'issuers.prod.yaml'
      )

      issuers.apply(@runners.k8s, prune: true)
    end

    define_task(Rake::Task, "prod:cluster:cloudflare-api-access" => ['cluster:namespaces']) do
      next if @remote_resources.infra_secrets.member?('cloudflare-api')

      token = prompt.mask("Cloudflare API token:") do |q|
        q.required true
        q.validate /\w+/
      end

      token = token.strip

      cloudflare_api_secret = K8s::Resource.new(
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

      K8s::Stack.new('cloudflare-api-secret', [cloudflare_api_secret]).apply(@runners.k8s)
    end

    @last_description = "installs an agent in the cluster to sync ingress hostnames with a DNS registrar"
    define_task(Rake::Task, "prod:cluster:external-dns-sync" => ['cluster:namespaces', 'prod:cluster:cloudflare-api-access']) do
      external_dns = K8s::Stack.load(
        'external-dns',
        local_resources / 'external-dns.yaml'
      )

      external_dns.apply(@runners.k8s, prune: true)
    end

    @last_description = "installs a High-Availability Redis instance into the cluster"
    define_task(Rake::Task, "prod:cluster:redis" => ['cluster:namespaces', 'local:helm-repos']) do
      @runners.helm.ensure_deployed('r', 'bitnami/redis',
        namespace: :production,
        config_map: {
          'master.resources.requests.memory' => '1Gi',
          'master.resources.requests.cpu' => '500m'
        }
      )
    end

    define_task(Rake::Task, 'local:helm-repos') do
      @runners.helm.register_repos({
        'stable' => 'https://charts.helm.sh/stable',
        'ingress-nginx' => 'https://kubernetes.github.io/ingress-nginx',
        'jetstack' => 'https://charts.jetstack.io',
        'bitnami' => 'https://charts.bitnami.com/bitnami'
      })
    end

    define_task(Rake::Task, 'cluster:infra-namespace') do
      next if @remote_resources.namespaces.member?('infrastructure')

      ns_resource = K8s::Resource.new(
        apiVersion: 'v1',
        kind: 'Namespace',
        metadata: {
          name: 'infrastructure'
        }
      )

      @remote_resources.namespaces.create_resource(ns_resource)
    end

    define_task(Rake::Task, 'cluster:ingress-controller' => ['cluster:infra-namespace', 'local:helm-repos']) do
      @runners.helm.ensure_deployed('lb', 'ingress-nginx/ingress-nginx',
        namespace: :infrastructure
      )

      @runners.helm.ensure_deployed('cert-manager', 'jetstack/cert-manager',
        namespace: :infrastructure,
        version_constraint: '^1.0.3',
        config_map: {
          installCRDs: true
        }
      )
    end
  end

  def run(argv = ARGV)
    standard_exception_handling do
      @runners.k8s.apis(prefetch_resources: true)
      init "orbital setup", argv
      add_orbital_tasks
      top_level
    end
  end
end
