# frozen_string_literal: true

require 'orbital/setup_task'

module Orbital; end
module Orbital::SetupTasks; end
module Orbital::SetupTasks::Local; end
class Orbital::SetupTasks::Local::SyncHelmRepos < Orbital::SetupTask
  dependent_on :helm

  def execute(*)
    log :step, "registering and syncing Helm chart repositories"

    self.helm_client.register_repos({
      'stable' => 'https://charts.helm.sh/stable',
      'ingress-nginx' => 'https://kubernetes.github.io/ingress-nginx',
      'jetstack' => 'https://charts.jetstack.io',
      'bitnami' => 'https://charts.bitnami.com/bitnami'
    })
  end
end
