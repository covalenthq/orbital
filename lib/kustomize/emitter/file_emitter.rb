require 'yaml'

require 'kustomize/emitter'
require 'kustomize/emitter/document_emitter'

class Kustomize::Emitter::FileEmitter < Kustomize::Emitter
  def initialize(source_path, session:)
    @session = session
    @source_path = source_path
  end

  def input_emitters
    return @input_emitters if @input_emitters

    source_docs = YAML.load_stream(@source_path.read)

    @input_emitters = source_docs.map.with_index do |doc, i|
      unless doc.has_key?('kind')
        raise ArgumentError, "invalid Kubernetes resource-config document (missing attribute 'kind'): subdocument #{i} in #{target_path}"
      end

      doc_kind = doc['kind']

      doc_klass =
        begin
          Kustomize::Emitter::DocumentEmitter.const_get(doc_kind + 'DocumentEmitter')
        rescue NameError => e
          Kustomize::Emitter::DocumentEmitter
        end

      doc_klass.load(
        doc,
        source: {path: @source_path, subdocument: i},
        session: @session
      )
    end
  end
end
