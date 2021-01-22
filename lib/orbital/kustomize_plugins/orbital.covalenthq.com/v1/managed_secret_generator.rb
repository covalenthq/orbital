require 'set'
require 'base64'

require 'digest/base32'

require 'kustomize/generator_plugin'

module Orbital; end
module Orbital::KustomizePlugins; end

class Orbital::KustomizePlugins::ManagedSecretGenerator < Kustomize::GeneratorPlugin
  match_on api_version: 'orbital.covalenthq.com/v1'

  def initialize(rc)
    @match_names = Set.new(rc['import'] || [])
    @use_namespace = rc.dig('template', 'namespace')
  end

  def secret_manager
    @secret_manager ||= self.session.orbital_context.project.secret_manager
  end

  def input_resources
    self.secret_manager.secrets.map(&:to_yaml_doc)
  end

  def emit
    self.secret_manager.secrets.values
    .find_all{ |sec| @match_names.member?(sec.name) }
    .map{ |sec| build_rc(sec) }
  end

  private
  def build_rc(sec)
    case sec.sealing_state
    when :fully_sealed
      build_sealed_secret_rc(sec)
    when :partially_sealed
      build_sealed_secret_rc(seal_rest(sec))
    when :unsealed
      build_plain_secret_rc(sec)
    end
  end

  private
  def seal_rest(sec)
    sec = sec.deep_copy
    sec.parts.values.each(&:seal!)
    sec
  end

  PLAIN_SECRET_API_VERSION = 'v1'
  PLAIN_SECRET_KIND = 'Secret'

  private
  def build_plain_secret_rc(sec)
    armored_data_parts = sec.parts.values.map do |part|
      v = part.get_plain_value!
      [part.key, Base64.encode64(v)]
    end.to_h

    {
      'apiVersion' => PLAIN_SECRET_API_VERSION,
      'kind' => PLAIN_SECRET_KIND,
      'metadata' => {
        'namespace' => @use_namespace,
        'name' => sec.name.to_s
      },
      'type' => sec.type.to_s,
      'data' => armored_data_parts
    }
  end

  SEALED_SECRET_API_VERSION = 'bitnami.com/v1alpha1'
  SEALED_SECRET_KIND = 'SealedSecret'

  KUSTOMIZER_DIGEST_ANNOT = 'kustomizer.covalenthq.com/effective-fingerprint'

  def build_sealed_secret_rc(sec)
    parts_manifest =
      sec.parts.values
      .map{ |part| "#{part.key}=#{part.value_digest}\n" }
      .join

    fingerprint =
      Digest::SHA256.base32digest(parts_manifest, :zbase32)[0, 6]

    armored_data_parts = sec.parts.values.map do |part|
      v = part.get_sealed_value!(in_namespace: @use_namespace)
      [part.key, Base64.encode64(v)]
    end.to_h

    {
      'apiVersion' => SEALED_SECRET_API_VERSION,
      'kind' => SEALED_SECRET_KIND,
      'metadata' => {
        'namespace' => @use_namespace,
        'name' => sec.name.to_s,
        'annotations' => {
          KUSTOMIZER_DIGEST_ANNOT => fingerprint
        }
      },
      'spec' => {
        'template' => {
          'type' => sec.type.to_s,
        },
        'encryptedData' => armored_data_parts
      }
    }
  end
end
