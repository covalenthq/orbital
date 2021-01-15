module Kustomize; end

class Kustomize::TargetSpec
  def self.create(target_spec)
    self.new(
      api_group: target_spec['group'],
      api_version: target_spec['version'],

      kind: target_spec['kind'],

      namespace: target_spec['namespace'],
      name: target_spec['name']
    )
  end

  def initialize(api_group: nil, api_version: nil, kind: nil, name: nil, namespace: nil)
    @match_api_group = api_group
    @match_api_version = api_version
    @match_kind = kind
    @match_namespace = namespace
    @match_name = name
  end

  def get_name(rc)
    rc.dig('spec', 'name')
  end

  def get_namespace(rc)
    rc.dig('spec', 'namespace') || 'default'
  end

  def match?(rc)
    if @match_api_group or @match_api_version
      api_group, api_version = (rc['apiVersion'] || '/').split('/', 2)
      return false if @match_api_group and api_group != @match_api_group
      return false if @match_api_version and api_version != @match_api_version
    end

    return false if @match_kind and (rc['kind'] != @match_kind)
    return false if @match_name and get_name(resource_doc) != @match_name
    return false if @match_namespace and get_namespace(resource_doc) != @match_namespace

    true
  end
end
