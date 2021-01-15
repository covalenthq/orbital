require 'json'
require 'digest'
require 'set'

require 'accessory'
require 'digest/base32'

require 'kustomize/transform'
require 'kustomize/emitter/document_emitter/kustomization_document_emitter'

class Kustomize::Transform::NameDigestAutosuffixTransform < Kustomize::Transform
  include Accessory

  SUFFIX_JOINER = "-"

  def self.create(kustomize_doc)
    raise ArgumentError unless kustomize_doc.kind_of?(Kustomize::Emitter::DocumentEmitter::KustomizationDocumentEmitter)
    self.new(kustomize_doc)
  end

  def initialize(kustomize_doc)
    @kustomize_doc = kustomize_doc
  end

  SECRET_KINDS = Set[
    'Secret',
    'SealedSecret'
  ]

  def suffixes
    return @suffixes if @suffixes

    secret_docs =
      @kustomize_doc.input_resources
      .filter{ |rc| SECRET_KINDS.member?(rc['kind']) }

    @suffixes =
      secret_docs.map do |rc|
        rc_kind = rc['kind']

        secret_name = NAME_LENSES_BY_KIND[rc_kind].first.get_in(rc)
        secret_content = CONTENT_LENSES_BY_KIND[rc_kind].get_in(rc)
        content_hash_suffix = Digest::SHA256.base32digest(secret_content.to_json, :zbase32)[0, 8]

        [secret_name, content_hash_suffix]
      end.to_h
  end

  CONTENT_LENSES_BY_KIND = {
    "Secret" => Lens["data"],
    "SealedSecret" => Lens["spec", "encryptedData"]
  }

  NAME_LENSES_BY_KIND = {
    "Deployment" => [
      Lens["spec", "template", "spec", "containers", Access.all, "env", Access.all, "valueFrom", "secretKeyRef", "name"]
    ],

    "Secret" => [
      Lens["metadata", "name"]
    ],

    "SealedSecret" => [
      Lens["spec", "template", "metadata", "name"]
    ]
  }

  def apply(rc_doc)
    name_lenses = NAME_LENSES_BY_KIND[rc_doc['kind']]
    return rc_doc unless name_lenses

    name_lenses.inject(rc_doc) do |doc, lens|
      lens.update_in(doc) do |orig_name|
        if self.suffixes.has_key?(orig_name)
          new_name = [orig_name, self.suffixes[orig_name]].join('-')
          [:set, new_name]
        else
          :keep
        end
      end
    end
  end
end
