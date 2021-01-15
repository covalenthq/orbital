require 'kustomize/json_6902_patch'

class Kustomize::Json6902Patch::ReplaceOp < Kustomize::Json6902Patch::Op
  def self.create(patch_spec)
    new(
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
