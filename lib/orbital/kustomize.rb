require 'pathname'
require 'yaml'

module Orbital; end
module Orbital::Kustomize; end
class Orbital::Kustomize::KustomizationFile
  FILENAME_SPEC = 'kustomization.yaml'
  DOC_KIND = 'Kustomization'

  def self.load(target_path)
    target_path = Pathname.new(target_path.to_s) unless target_path.kind_of?(Pathname)
    if target_path.file?
      unless target_path.basename.to_s == FILENAME_SPEC
        raise ArgumentError, "Explicitly-passed files must be named #{FILENAME_SPEC}: #{target_path}"
      end
      # ok
    elsif target_path.directory?
      target_path = target_path / FILENAME_SPEC
      raise Errno::ENOENT, target_path.to_s unless target_path.file?
    else
      raise Errno::ENOENT, target_path.to_s
    end

    target_doc = YAML.load(target_path.read)

    unless target_doc['kind'] == DOC_KIND
      raise ArgumentError, "invalid #{FILENAME_SPEC} file: #{target_path}"
    end

    self.new(target_path, target_doc)
  end

  def initialize(path, doc)
    @path = path
    @doc = doc
  end

  def directory
    @path.parent
  end

  def parents
    return @parents if @parents

    @parents = (@doc['bases'] || []).map do |rel_path|
      self.class.load(self.directory / rel_path)
    end
  end

  def own_file_resources
    return @own_file_resources if @own_file_resources

    @own_file_resources = (@doc['resources'] || []).flat_map do |rel_path|
      abs_path = self.directory / rel_path
      YAML.load_stream(abs_path.read)
    end
  end

  def file_resources
    return @file_resources if @file_resources
    (self.parents.map(&:file_resources) + self.own_file_resources).flatten
  end

  def resource_configs
    self.file_resources
  end



  def own_json_patch_transformers
    ((@doc['patches'] || []) + (@doc['patchesJson6902'] || [])).map do |op_spec|
      Orbital::Kustomize::Json6902PatchOp.create(self, op_spec)
    end
  end

  def json_patch_transformers
    (self.parents.map(&:json_patch_transformers) + self.own_json_patch_transformers).flatten
  end


  def own_image_transformers
    (@doc['images'] || []).map do |op_spec|
      Orbital::Kustomize::ImagePatchOp.create(op_spec)
    end
  end

  def image_transformers
    (self.parents.map(&:image_transformers) + self.own_image_transformers).flatten
  end

  def transformers
    self.image_transformers + self.json_patch_transformers
  end


  def render_docs
    self.resource_configs.map do |rc|
      self.transformers.inject(rc){ |doc, xform| xform.apply(doc) }
    end
  end

  def render_stream
    self.render_docs.map{ |doc| doc.to_yaml }.join("")
  end
end

class Orbital::Kustomize::ImagePatchOp
  def self.create(op_spec)
    raise ArgumentError, "cannot specify both newTag and digest" if op_spec['newTag'] and op_spec['digest']

    self.new(
      name: op_spec['name'],
      new_name: op_spec['newName'],
      new_tag: op_spec['newTag'],
      new_digest: op_spec['digest']
    )
  end

  def initialize(name:, new_name: nil, new_tag: nil, new_digest: nil)
    @name = name
    @new_name = new_name
    @new_tag = new_tag
    @new_digest = new_digest
  end

  def apply(resource_doc)
    pos =
      if template = resource_doc.dig('spec', 'template')
        template
      else
        resource_doc
      end

    pos = pos.dig('spec', 'containers')
    return resource_doc unless pos

    pos.each do |container|
      image_parts = /^(.+?)([:@])(.+)$/.match(container['image'])
      image_parts = if image_parts
        {name: image_parts[1], sigil: image_parts[2], ref: image_parts[3]}
      else
        {name: container['image'], sigil: ':', ref: 'latest'}
      end

      if @new_name
        image_parts[:name] = new_name
      end
      if @new_tag
        image_parts[:sigil] = ':'
        image_parts[:ref] = @new_tag
      end
      if @new_digest
        image_parts[:sigil] = '@'
        image_parts[:ref] = @new_digest
      end

      container['image'] = "#{image_parts[:name]}#{image_parts[:sigil]}#{image_parts[:ref]}"
    end

    resource_doc
  end
end


class Orbital::Kustomize::Json6902PatchOp
  def self.create(kustomization_file, op_spec)
    target = Orbital::Kustomize::TargetSpec.create(op_spec['target'])

    patch_part =
      if op_spec['path']
        path = kustomization_file.directory / op_spec['path']
        YAML.load(file.read)
      elsif op_spec['patch']
        YAML.load(op_spec['patch'])
      else
        []
      end

    patches = patch_part.map do |patch|
      Orbital::Kustomize::Json6902Patch
      .const_get(patch['op'].capitalize)
      .create(patch)
    end

    self.new(
      target: target,
      patches: patches
    )
  end

  def initialize(target:, patches:)
    @target = target
    @patches = patches
  end

  def apply(resource_doc)
    if @target.match?(resource_doc)
      @patches.inject(resource_doc){ |doc, patch| patch.apply(doc) }
    else
      resource_doc
    end
  end
end

class Orbital::Kustomize::TargetSpec
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

  def get_name(resource_doc)
    resource_doc.dig('spec', 'name')
  end

  def get_namespace(resource_doc)
    resource_doc.dig('spec', 'namespace') || 'default'
  end

  def match?(resource_doc)
    if @match_api_group or @match_api_version
      api_group, api_version = resource_doc['apiVersion'].split('/', 2)
      return false if @match_api_group && api_group != @match_api_group
      return false if @match_api_version && api_version != @match_api_version
    end
    return false if @match_kind && resource_doc['kind'] != @match_api_kind
    return false if @match_name && get_name(resource_doc) != @match_name
    return false if @match_namespace && get_namespace(resource_doc) != @match_namespace

    true
  end
end

class Orbital::Kustomize::Json6902Patch
  def parse_path(path)
    path[1..-1].split("/").map do |e|
      e = e.gsub('~1', '/')
      if e.match?(/^\d+$/)
        e.to_i
      else
        e
      end
    end
  end
end

class Orbital::Kustomize::Json6902Patch::Add < Orbital::Kustomize::Json6902Patch
  def self.create(patch_spec)
    self.new(
      path: patch_spec['path'],
      value: patch_spec['value']
    )
  end

  def initialize(path:, value:)
    @path = parse_path(path)
    @value = value
  end

  def apply(resource_doc)
    walk_path, target_key = @path[1..-2], @path[-1]
    pos = resource_doc.dig(walk_path)
    return ArgumentError, "invalid path" unless pos
    return ArgumentError, "resource exists at path" if pos[target_key]
    pos[target_key] = @value
    resource_doc
  end
end


class Orbital::Kustomize::Json6902Patch::Replace < Orbital::Kustomize::Json6902Patch
  def self.create(patch_spec)
    self.new(
      path: patch_spec['path'],
      value: patch_spec['value']
    )
  end

  def initialize(path:, value:)
    @path = parse_path(path)
    @value = value
  end

  def apply(resource_doc)
    walk_path, target_key = @path[1..-2], @path[-1]
    pos = resource_doc.dig(walk_path)
    return ArgumentError, "invalid path" unless pos
    return ArgumentError, "resource does not exist at path" unless pos[target_key]
    pos[target_key] = @value
    resource_doc
  end
end

class Orbital::Kustomize::Json6902Patch::Remove < Orbital::Kustomize::Json6902Patch
  def self.create(patch_spec)
    self.new(
      path: patch_spec['path']
    )
  end

  def initialize(path:)
    @path = parse_path(path)
  end

  def apply(resource_doc)
    walk_path, target_key = @path[1..-2], @path[-1]
    pos = resource_doc.dig(walk_path)
    return ArgumentError, "invalid path" unless pos
    if pos.kind_of?(Array)
      pos.delete_at(target_key)
    else
      pos.delete(target_key)
    end
    resource_doc
  end
end
