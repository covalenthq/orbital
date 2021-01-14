require 'json'
require 'yaml'
require 'digest'

require 'accessory'
require 'digest/base32'

require 'orbital/kustomize/pathname_refinements'

using Orbital::Kustomize::PathnameRefinements

class Orbital::Kustomize::Emitter
  def input_emitters; []; end

  def input_resources
    self.input_emitters.flat_map(&:emit)
  end

  def emit
    self.input_resources
  end

  def to_yaml_stream
    self.emit.map(&:to_yaml).join("")
  end
end

class Orbital::Kustomize::FileEmitter < Orbital::Kustomize::Emitter
  def initialize(source_path)
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
          Orbital::Kustomize.const_get(doc_kind + 'DocumentEmitter')
        rescue NameError => e
          Orbital::Kustomize::DocumentEmitter
        end

      doc_klass.load(doc, source: {path: @source_path, subdocument: i})
    end
  end
end

class Orbital::Kustomize::DocumentEmitter < Orbital::Kustomize::Emitter
  def self.load(doc, source:)
    self.new(doc, source: source)
  end

  def initialize(doc, source: nil)
    @doc = doc
    @source = source
  end

  def emit
    [@doc]
  end
end

class Orbital::Kustomize::DirectoryEmitter < Orbital::Kustomize::Emitter
  def initialize(source_path)
    @source_path = source_path
  end

  KUSTOMIZATION_FILENAME = 'kustomization.yaml'

  def kustomization_file_path
    @source_path / KUSTOMIZATION_FILENAME
  end

  def input_emitters
    return @input_emitters if @input_emitters

    @input_emitters =
      if self.kustomization_file_path.file?
        kf_emitter = Orbital::Kustomize::FileEmitter.new(self.kustomization_file_path)
        [kf_emitter]
      else
        @source_path.all_rc_files_within.flat_map do |rc_path|
          Orbital::Kustomize::FileEmitter.new(rc_path)
        end
      end
  end
end

class Orbital::Kustomize::KustomizationDocumentEmitter < Orbital::Kustomize::DocumentEmitter
  def source_directory
    @source[:path].parent
  end

  def input_emitters
    return @input_emitters if @input_emitters

    pathspecs =
      (@doc['bases'] || []) +
      (@doc['resources'] || [])

    @input_emitters = pathspecs.map do |rel_path|
      abs_path = self.source_directory / rel_path

      unless abs_path.exist?
        raise Errno::ENOENT, abs_path.to_s
      end

      if abs_path.file?
        Orbital::Kustomize::FileEmitter.new(abs_path)
      elsif abs_path.directory?
        Orbital::Kustomize::DirectoryEmitter.new(abs_path)
      else
        raise Errno::EFTYPE, abs_path.to_s
      end
    end
  end

  def json_patch_transformers
    ((@doc['patches'] || []) + (@doc['patchesJson6902'] || [])).map do |op_spec|
      Orbital::Kustomize::Json6902PatchOp.create(self, op_spec)
    end
  end

  def image_transformers
    (@doc['images'] || []).map do |op_spec|
      Orbital::Kustomize::ImagePatchOp.create(op_spec)
    end
  end

  def namespace_transformers
    if new_ns = @doc['namespace']
      [Orbital::Kustomize::NamespacePatchOp.create(new_ns)]
    else
      []
    end
  end

  def secret_name_transformers
    [Orbital::Kustomize::SecretNamePatchOp.create(self)]
  end

  def transformers
    [
      self.namespace_transformers,
      self.image_transformers,
      self.secret_name_transformers,
      self.json_patch_transformers
    ].flatten
  end

  def emit
    self.input_resources.map do |rc|
      self.transformers.inject(rc){ |doc, xform| xform.apply(doc) }
    end
  end
end



class Orbital::Kustomize::NamespacePatchOp
  include Accessory

  def self.create(new_ns)
    self.new(new_ns)
  end

  def initialize(new_ns)
    @new_ns = new_ns
  end

  LENSES_FOR_ALL = [
    Lens["metadata", "namespace"]
  ]

  LENSES_FOR_ALL_BLACKLIST_PAT = /^Cluster/

  LENSES_FOR_KIND = {
    "ClusterRoleBinding" => [
      Lens["subjects", Access.all, "namespace"]
    ],

    "RoleBinding" => [
      Lens["subjects", Access.all, "namespace"]
    ],

    "SealedSecret" => [
      Lens["spec", "template", "metadata", "namespace"]
    ]
  }

  def apply(rc_doc)
    rc_kind = rc_doc['kind']
    use_lenses = []

    unless rc_kind =~ LENSES_FOR_ALL_BLACKLIST_PAT
      use_lenses += LENSES_FOR_ALL
    end

    if lenses_for_doc_kind = LENSES_FOR_KIND[rc_kind]
      use_lenses += lenses_for_doc_kind
    end

    use_lenses.inject(rc_doc) do |doc, lens|
      lens.put_in(doc, @new_ns)
    end
  end
end

class Orbital::Kustomize::SecretNamePatchOp
  include Accessory

  SUFFIX_JOINER = "-"

  def self.create(kustomize_doc)
    raise ArgumentError unless kustomize_doc.kind_of?(Orbital::Kustomize::KustomizationDocumentEmitter)
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


class Orbital::Kustomize::ImagePatchOp
  include Accessory

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

  LENS_BY_KIND = {
    "Deployment" => Lens["spec", "template", "spec", "containers", Access.all, "image"]
  }

  def apply(rc_doc)
    lens = LENS_BY_KIND[rc_doc['kind']]
    return rc_doc unless lens

    lens.update_in(rc_doc) do |image_str|
      image_parts = /^(.+?)([:@])(.+)$/.match(image_str)

      image_parts = if image_parts
        {name: image_parts[1], sigil: image_parts[2], ref: image_parts[3]}
      else
        {name: container['image'], sigil: ':', ref: 'latest'}
      end

      unless image_parts[:name] == @name
        next(:keep)
      end

      if @new_name
        image_parts[:name] = new_name
      end

      if @new_tag
        image_parts[:sigil] = ':'
        image_parts[:ref] = @new_tag
      elsif @new_digest
        image_parts[:sigil] = '@'
        image_parts[:ref] = @new_digest
      end

      new_image_str = "#{image_parts[:name]}#{image_parts[:sigil]}#{image_parts[:ref]}"
      [:set, new_image_str]
    end
  end
end

class Orbital::Kustomize::Json6902PatchOp
  def self.create(kustomization_file, op_spec)
    target = Orbital::Kustomize::TargetSpec.create(op_spec['target'])

    patch_part =
      if op_spec['path']
        path = kustomization_file.source_directory / op_spec['path']
        YAML.load(file.read)
      elsif op_spec['patch']
        YAML.load(op_spec['patch'])
      elsif op_spec['ops']
        op_spec['ops']
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

  attr_reader :target
  attr_reader :patches

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

class Orbital::Kustomize::Json6902Patch
  def parse_lens(path)
    lens_parts = path[1..-1].split("/").map do |e|
      e = e.gsub('~1', '/')
      if e == ":all"
        Accessory::Access.all
      elsif e.match?(/^\d+$/)
        e.to_i
      else
        e
      end
    end

    Accessory::Lens[*lens_parts]
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
    @lens = parse_lens(path)
    @new_value = value
  end

  def apply(rc)
    @lens.update_in(rc) do |orig_value|
      unless orig_value.nil?
        raise ArgumentError, "cannot add value at #{@lens.inspect} -- value exists at target"
      end

      [:set, @new_value]
    end
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
    @lens = parse_lens(path)
    @new_value = value
  end

  def apply(rc)
    @lens.update_in(rc) do |orig_value|
      if orig_value.nil?
        raise ArgumentError, "cannot set value at #{@lens.inspect} -- target does not exist"
      end

      [:set, @new_value]
    end
  end
end

class Orbital::Kustomize::Json6902Patch::Remove < Orbital::Kustomize::Json6902Patch
  def self.create(patch_spec)
    self.new(
      path: patch_spec['path']
    )
  end

  def initialize(path:)
    @lens = parse_lens(path)
  end

  def apply(rc0)
    _, rc1 = @lens.pop_in(rc0)
    rc1
  end
end
