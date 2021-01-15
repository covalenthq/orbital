require 'kustomize/json_6902_patch'

class Kustomize::Json6902Patch::RemoveOp < Kustomize::Json6902Patch::Op
  def self.create(patch_spec)
    new(
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
