require 'accessory'

require 'kustomize/transform'

class Kustomize::Transform::NamespaceTransform < Kustomize::Transform
  include Accessory

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
