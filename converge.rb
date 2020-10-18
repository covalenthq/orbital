#!/usr/bin/env ruby

require 'pathname'
require_relative 'converger/helm'
require_relative 'converger/kubectl'

k8s_cfgs_dir = Pathname.new(__FILE__).parent / 'configs'

helm = Helm.new
k8s_cfgs = Kubectl.new(k8s_cfgs_dir)

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

k8s_cfgs[:letsencrypt].apply_all!

k8s_cfgs[:kuard].apply_all!
