require 'pathname'

require 'kustomize/session'

require 'kustomize/emitter/file_emitter'
require 'kustomize/emitter/directory_emitter'
require 'kustomize/emitter/document_emitter/kustomization_document_emitter'

module Kustomize
  def self.load(rel_path_or_rc, session: Kustomize::Session.new, source_path: nil)
    case rel_path_or_rc
    when String, Pathname
      load_path(rel_path_or_rc, session: session)
    when Hash
      load_doc(rel_path_or_rc, session: session, source_path: source_path)
    else
      raise ArgumentError, "must be a kustomization document or a path to one, instead got: #{rel_path_or_rc.inspect}"
    end
  end

  def self.load_doc(rc, session: Kustomize::Session.new, source_path:)
    Kustomize::Emitter::DocumentEmitter::KustomizationDocumentEmitter
    .load(rc, source: source_path, session: session)
  end

  def self.load_path(rel_path, session: Kustomize::Session.new)
    rel_path = Pathname.new(rel_path.to_s) unless rel_path.kind_of?(Pathname)

    unless rel_path.exist?
      raise Errno::ENOENT, rel_path.to_s
    end

    abs_path = rel_path.expand_path

    if abs_path.file?
      Kustomize::Emitter::FileEmitter.new(abs_path, session: session)
    elsif abs_path.directory?
      Kustomize::Emitter::DirectoryEmitter.new(abs_path, session: session)
    else
      raise Errno::EFTYPE, rel_path.to_s
    end
  end
end
