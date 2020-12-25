# frozen_string_literal: true

require 'set'
require 'pathname'
require 'securerandom'
require 'ostruct'
require 'paint'

require 'active_support/core_ext/string'
require 'k8s-ruby'
require 'tty-prompt'

require 'orbital/environment'
require 'orbital/command'
require 'orbital/converger'

require 'orbital/converger/helm'
require 'orbital/converger/mkcert'
require 'orbital/converger/gcloud'

module Orbital; end
module Orbital::Commands; end
class Orbital::Commands::Setup < Orbital::Command
  def initialize(*args)
    super(*args)

    # ARGV currently contains ['setup'], so get rid of that
    ARGV.shift

    @paths = OpenStruct.new
    @paths.local_resources = @paths.sdk_root / 'share' / 'setup' / 'resources'
    @paths.gcloud_service_accounts = @environment.sdk.state_dir / 'setup' / 'gcloud-service-accts'
    @paths.local_ca_cert = @environment.sdk.state_dir / 'setup' / 'local-ca-cert'

    @task_involves = Set.new

    # TODO: parse out task name
    @task_name = ARGV.shift
    usage ["No task name given."] unless @task_name
    @task_name = @task_name.underscore.intern

    (TASK_INVOLVES[@task_name] || []).each do |involved_part|
      @task_involves.add(involved_part)
    end
  end

  TASK_INVOLVES = {
    cluster_namespaces: [:cluster],
    local_ca_cert: [:mkcert],
    local_dns_proxy: [:brew],
  }



  def validate_environment!
    return if @environment_validated

    log :step, "ensure shell environment is sane for setup"

    if @task_involves.member?(:cluster)
      @environment.validate :has_kubeconfig do
        if @environment.shell.kubectl_config_path.file?
          log :success, ["shell is configured with a kubectl cluster (", Paint["~/.kube/config", :bold], " is available)"]
        else
          fatal [Paint["~/.kube/config", :bold], " is not configured. Please set up a (local or remote) k8s cluster."]
        end
      end
    end

    if @task_involves.member?(:mkcert)
      @environment.validate :cmd_mkcert do
        exec_exist! 'mkcert', ["run:\n", "  ", Paint["brew install mkcert", :bold]]
      end
    end

    if @task_involves.member?(:gcloud)
      @environment.validate :cmd_gcloud do
        exec_exist! 'gcloud', [link_to(
          "https://cloud.google.com/sdk/docs/install",
          "install the Google Cloud SDK."
        ), '.']
      end
    end

    if @task_involves.member?(:helm)
      @environment.validate :cmd_helm do
        exec_exist! 'helm', [link_to(
          "https://helm.sh/docs/intro/install/",
          "install Helm."
        ), '.']
      end
    end

    if @task_involves.member?(:brew)
      @environment.validate :cmd_brew do
        exec_exist! 'brew', [link_to(
          "https://brew.sh/",
          "install Homebrew."
        ), '.']
      end
    end

    @environment_validated = true
  end

  def k8s_client
    @k8s_client ||= K8s::Client.config(K8s::Config.load_file(@environment.shell.kubectl_config_path))
  end

  def gcloud_client
    @gcloud_client ||= GCloud.new(@paths.gcloud_service_accounts)
  end

  def helm_client
    @helm_client ||= Helm.new
  end

  def mkcert_client
    @mkcert_client ||= MkCert.new(@paths.local_ca_cert)
  end

  def cluster_namespaces
    @k8s_client.api('v1').resource('namespaces')
  end

  def cluster_infra_secrets
    @k8s_client.api('v1').resource('secrets', namespace: 'infrastructure')
  end

  def cluster_service_accounts
    @k8s_client.api('v1').resource('serviceaccounts', namespace: 'default')
  end

  def has_resource?(resource_set, resource_name)
    resource_set.list(fieldSelector: "metadata.name=#{resource_name}").length > 0
  end

end


module Orbital; end
class Orbital::Converger < Rake::Application

  def add_orbital_tasks
    @last_description = "sets up a local development cluster"
    define_task(Rake::Task, 'dev:base' => [
      'dev:cluster:namespaces',
      'dev:cluster:ingress-controller',
      'dev:cluster:registry-access',
    ])


    @last_description = "installs a DNS proxy on the host to enable DNS resolution of cluster services"

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
      next if @remote_resources.infra_secrets.has_resource?('local-ca')

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

      next if @remote_resources.infra_secrets.has_resource?('covalent-project-gcr-auth')

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
      next if @remote_resources.infra_secrets.has_resource?('cloudflare-api')

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

    define_task(Rake::Task, 'cluster:infra-namespace') do
      next if @remote_resources.namespaces.has_resource?('infrastructure')

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
