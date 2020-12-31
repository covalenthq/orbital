# frozen_string_literal: true

  def add_orbital_tasks
    @last_description = "sets up a local development cluster"
    define_task(Rake::Task, 'dev:base' => [
      'dev:cluster:namespaces',
      'dev:cluster:ingress-controller',
      'dev:cluster:registry-access',
    ])


    @last_description = ""

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
