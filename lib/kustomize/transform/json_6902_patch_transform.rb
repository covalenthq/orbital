require 'yaml'

require 'kustomize/transform'
require 'kustomize/target_spec'

require 'kustomize/json_6902_patch/add_op'
require 'kustomize/json_6902_patch/replace_op'
require 'kustomize/json_6902_patch/remove_op'
require 'kustomize/json_6902_patch/gsub_op'

class Kustomize::Transform::Json6902PatchTransform < Kustomize::Transform
  def self.create(kustomization_file, op_spec)
    target = Kustomize::TargetSpec.create(op_spec['target'])

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
      Kustomize::Json6902Patch
      .const_get(patch['op'].capitalize + 'Op')
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
