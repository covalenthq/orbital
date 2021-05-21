require 'kustomize/transformer_plugin'
require 'kustomize/transform/image_transform'

module Orbital; end
module Orbital::KustomizePlugins; end

class Orbital::KustomizePlugins::ImageRefsFromReleaseTransformer < Kustomize::TransformerPlugin
  match_on api_version: 'orbital.covalenthq.com/v1'

  def initialize(_rc)
    # ok
  end

  LENS_BY_KIND = Kustomize::Transform::ImageTransform::LENS_BY_KIND

  def image_names_sieve
    return @image_names_sieve if @image_names_sieve

    @image_names_sieve =
      self.session.orbital_context.project.artifact_blueprints
      .values
      .flatten
      .filter{ |a| a[:builder] == :docker_image }
      .map{ |a| a.dig(:params, :image_name) }
      .compact
      .to_set
  end

  def new_refs
    return @new_refs if @new_refs

    pr = self.session.orbital_context.project.proposed_release
    return @new_refs = {} unless pr

    afs = pr.artifacts.values
      .filter{ |af| af['type'] == 'DockerImage' && af.has_key?('image.digest') }
      .map{ |af| [af['image.name'], af['image.digest']] }
      .to_h

    @new_refs = self.image_names_sieve.map do |image_name|
      image_digest = afs[image_name]
      if image_digest
        [image_name, {sigil: '@', ref: image_digest}]
      else
        [image_name, {sigil: ':', ref: pr.tag.name}]
      end
    end.to_h
  end

  def rewrite(rc_doc)
    lens = LENS_BY_KIND[rc_doc['kind']]
    return rc_doc unless lens

    lens.update_in(rc_doc) do |image_str|
      image_parts = /^(.+?)([:@])(.+)$/.match(image_str)

      image_parts = if image_parts
        {name: image_parts[1], ref: image_parts[3]}
      else
        {name: container['image'], ref: 'latest'}
      end

      new_ref = self.new_refs[image_parts[:name]]

      next(:keep) unless new_ref

      new_image_str = "#{image_parts[:name]}#{new_ref[:sigil]}#{new_ref[:ref]}"

      [:set, new_image_str]
    end
  end
end
