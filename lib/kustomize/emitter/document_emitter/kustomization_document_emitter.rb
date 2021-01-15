require 'kustomize/emitter/document_emitter'
require 'kustomize/emitter/file_emitter'
require 'kustomize/emitter/directory_emitter'
require 'kustomize/emitter/plugin_emitter'

require 'kustomize/transform/json_6902_patch_transform'
require 'kustomize/transform/image_transform'
require 'kustomize/transform/namespace_transform'
require 'kustomize/transform/name_digest_autosuffix_transform'

class Kustomize::Emitter::DocumentEmitter::KustomizationDocumentEmitter < Kustomize::Emitter::DocumentEmitter
  def source_directory
    @source[:path].parent
  end

  def input_emitters
    return @input_emitters if @input_emitters

    rc_pathspecs =
      (@doc['bases'] || []) +
      (@doc['resources'] || [])

    gen_pathspecs =
      (@doc['generators'] || [])

    input_emitters = rc_pathspecs.map do |rel_path|
      build_input_emitter(rel_path)
    end

    input_emitters += gen_pathspecs.map do |rel_path|
      Kustomize::Emitter::PluginEmitter.new(
        build_input_emitter(rel_path),
        session: @session
      )
    end

    @input_emitters = input_emitters
  end

  def build_input_emitter(rel_path)
    abs_path = self.source_directory / rel_path

    unless abs_path.exist?
      raise Errno::ENOENT, abs_path.to_s
    end

    if abs_path.file?
      Kustomize::Emitter::FileEmitter.new(abs_path, session: @session)
    elsif abs_path.directory?
      Kustomize::Emitter::DirectoryEmitter.new(abs_path, session: @session)
    else
      raise Errno::EFTYPE, abs_path.to_s
    end
  end
  private :build_input_emitter

  def json_6902_patch_transforms
    ((@doc['patches'] || []) + (@doc['patchesJson6902'] || [])).map do |op_spec|
      Kustomize::Transform::Json6902PatchTransform.create(self, op_spec)
    end
  end

  def image_transforms
    (@doc['images'] || []).map do |op_spec|
      Kustomize::Transform::ImageTransform.create(op_spec)
    end
  end

  def namespace_transforms
    if new_ns = @doc['namespace']
      [Kustomize::Transform::NamespaceTransform.create(new_ns)]
    else
      []
    end
  end

  def name_digest_autosuffix_transforms
    [Kustomize::Transform::NameDigestAutosuffixTransform.create(self)]
  end

  def transforms
    return @transforms if @transforms

    @transforms = [
      self.namespace_transforms,
      self.image_transforms,
      self.name_digest_autosuffix_transforms,
      self.json_6902_patch_transforms
    ].flatten
  end

  def emit
    self.input_resources.map do |rc|
      self.transforms.inject(rc){ |doc, xform| xform.apply(doc) }
    end
  end
end
