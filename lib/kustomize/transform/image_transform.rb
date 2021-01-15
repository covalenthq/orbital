require 'accessory'

require 'kustomize/transform/image_transform'

class Kustomize::Transform::ImageTransform < Kustomize::Transform
  include Accessory

  def self.create(op_spec)
    raise ArgumentError, "cannot specify both newTag and digest" if op_spec['newTag'] and op_spec['digest']

    new(
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
