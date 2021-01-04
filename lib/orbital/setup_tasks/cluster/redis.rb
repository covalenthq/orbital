# frozen_string_literal: true

require 'orbital/setup_task'

require 'orbital/setup_tasks/local/helm_repos'

module Orbital; end
module Orbital::SetupTasks; end
module Orbital::SetupTasks::Cluster; end
class Orbital::SetupTasks::Cluster::InstallRedis < Orbital::SetupTask
  dependent_on :cluster_access

  dependent_on Orbital::SetupTasks::Local::SyncHelmRepos

  def execute(*)
    @last_description = "installs a High-Availability Redis instance into the cluster"

    self.helm_client.ensure_deployed('r', 'bitnami/redis',
      namespace: :"redis-prod",
      config_map: {
        'master.resources.requests.memory' => '1Gi',
        'master.resources.requests.cpu' => '500m'
      }
    )
  end
end
