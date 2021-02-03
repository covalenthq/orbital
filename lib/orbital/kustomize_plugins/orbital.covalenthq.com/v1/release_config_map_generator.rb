require 'set'
require 'base64'

require 'digest/base32'
require 'recursive-open-struct'

require 'kustomize/generator_plugin'

module Orbital; end
module Orbital::KustomizePlugins; end

class Orbital::KustomizePlugins::ReleaseConfigMapGenerator < Kustomize::GeneratorPlugin
  match_on api_version: 'orbital.covalenthq.com/v1'

  def initialize(rc)
    @emit_ns = rc.dig('spec', 'template', 'namespace')
    @emit_name = rc.dig('spec', 'template', 'name')
  end

  def proposed_release
    self.session.orbital_context.project.proposed_release
  end

  def build_steps
    self.session.orbital_context.project.build_steps
  end

  def release_data
    if rel = self.proposed_release
      {
        'version' => rel.tag.name,
        'build.time' => rel.created_at.to_i,
        'git.ref' => rel.from_git_ref,
        'git.branch' => rel.from_git_branch
      }
    else
      {
        'version' => 'latest'
      }
    end
  end

  def emit
    [build_config_map_rc(self.proposed_release)]
  end

  KUSTOMIZER_DIGEST_ANNOT = 'kustomizer.covalenthq.com/effective-fingerprint'

  private
  def build_config_map_rc(rel)
    data_parts = self.release_data
    data_parts = data_parts.find_all{ |k, v| not(v.nil?) }.to_h

    var_members = data_parts.map{ |k, v| [k.to_s, v.to_s] }.to_h

    properties_member = data_parts.map do |k, v|
      "com.covalenthq.orbital.release.#{k}=#{v}\n"
    end.join('')

    all_members =
      var_members.merge({'release.properties' => properties_member})

    {
      'apiVersion' => 'v1',
      'kind' => 'ConfigMap',
      'metadata' => {
        'namespace' => @emit_ns,
        'name' => @emit_name,
        'annotations' => {
          KUSTOMIZER_DIGEST_ANNOT => ''
        }
      },
      'data' => all_members
    }
  end
end
