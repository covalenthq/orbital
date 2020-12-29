# frozen_string_literal: true

require 'orbital/setup_task'

module Orbital; end
module Orbital::SetupTasks; end
module Orbital::SetupTasks::Cluster; end
class Orbital::SetupTasks::Cluster::CreateNamespaces < Orbital::SetupTask
  dependent_on :cluster_access

  CORE_NAMESPACES = [
    'infrastructure',
    'staging',
    'production',
    'development'
  ]

  def execute(*)
    have_namespaces = self.cluster_namespaces.list.map{ |ns| ns.metadata.name }

    namespaces_to_create =
      (CORE_NAMESPACES - have_namespaces).map do |ns_name|
        ns_resource = K8s::Resource.new(
          apiVersion: 'v1',
          kind: 'Namespace',
          metadata: {
            name: ns_name
          }
        )
      end

    return if namespaces_to_create.empty?

    logger.step "creating namespaces in cluster"

    namespaces_to_create.each do |ns_resource|
      self.cluster_namespaces.create_resource(ns_resource)
      logger.success ["create namespace '", Paint[ns_resource.metadata.name, :bold], "'"]
    end
  end
end
