require 'kustomize/transformer_plugin'
require 'kustomize/transform/image_transform'

module Orbital; end
module Orbital::KustomizePlugins; end

class Orbital::KustomizePlugins::ImageTagsFromReleaseTransformer < Kustomize::TransformerPlugin
  match_on api_version: 'orbital.covalenthq.com/v1'

  def initialize(_rc)
    # ok
  end

  LENS_BY_KIND = Kustomize::Transform::ImageTransform::LENS_BY_KIND

  def image_names_sieve
    return @image_names_sieve if @image_names_sieve

    @image_names_sieve =
      self.session.orbital_context.project.build_steps
      .filter{ |a| a[:builder] == :docker_image }
      .map{ |a| a.dig(:params, :image_name) }
      .compact
      .to_set
  end

  def new_tag
    return @new_tag if @probed_new_tag
    @probed_new_tag = true

    @new_tag =
      if pr = self.session.orbital_context.project.proposed_release
        pr.tag.name
      end
  end

  def rewrite(rc_doc)
    lens = LENS_BY_KIND[rc_doc['kind']]
    return rc_doc unless lens

    lens.update_in(rc_doc) do |image_str|
      image_parts = /^(.+?)[:@](.+)$/.match(image_str)

      image_parts = if image_parts
        {name: image_parts[1], ref: image_parts[3]}
      else
        {name: container['image'], ref: 'latest'}
      end

      unless image_names_sieve.member?(image_parts[:name])
        next(:keep)
      end

      unless self.new_tag
        next(:keep)
      end

      image_parts[:ref] = self.new_tag

      new_image_str = "#{image_parts[:name]}:#{image_parts[:ref]}"

      [:set, new_image_str]
    end
  end
end
