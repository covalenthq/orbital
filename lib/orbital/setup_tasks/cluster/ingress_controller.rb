# frozen_string_literal: true

require 'orbital/setup_task'

require 'orbital/setup_tasks/local/ca_cert'
require 'orbital/setup_tasks/local/helm_repos'
require 'orbital/setup_tasks/cluster/namespaces'

module Orbital; end
module Orbital::SetupTasks; end
module Orbital::SetupTasks::Cluster; end
class Orbital::SetupTasks::Cluster::InstallIngressController < Orbital::SetupTask
  dependent_on :cluster_access

  dependent_on Orbital::SetupTasks::Local::SyncHelmRepos
  dependent_on Orbital::SetupTasks::Cluster::CreateNamespaces

  def initialize(*args)
    super(*args)

    if @options.cluster == :local
      self.class.dependent_on(Orbital::SetupTasks::Local::InstallCACert)
    end
  end

  def execute(*)
    issuers_rc_filename =
      case @options.cluster
      when :local; 'issuers.dev.yaml'
      when :gcloud; 'issuers.prod.yaml'
      end

    issuers_rc = K8s::Stack.load(
      'issuers',
      self.local_k8s_resources_path / issuers_rc_filename
    )

    issuers_rc.apply(self.k8s_client, prune: true)
  end
end
