require 'accessory'

module Kustomize; end
module Kustomize::Json6902Patch; end

class Kustomize::Json6902Patch::Op
  def self.create(...)
    new(...)
  end

  class << self
    private :new
  end

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
