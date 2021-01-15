require 'kustomize/json_6902_patch'

class Kustomize::Json6902Patch::GsubOp < Kustomize::Json6902Patch::Op
  def self.create(patch_spec)
    self.new(
      paths: patch_spec['paths'],
      pattern: Regexp.new(patch_spec['pattern'], Regexp::EXTENDED),
      replacement: patch_spec['replacement']
    )
  end

  def initialize(paths:, pattern:, replacement:)
    @lenses = paths.map{ |path| parse_lens(path) }
    @pattern = pattern
    @replacement = replacement
  end

  def apply(rc)
    @lenses.inject(rc) do |doc, lens|
      lens.update_in(doc) do |orig_value|
        new_value = orig_value.gsub(@pattern, @replacement)

        if new_value != orig_value
          [:set, new_value]
        else
          :keep
        end
      end
    end
  end
end
