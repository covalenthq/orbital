module Kustomize; end

class Kustomize::Transform
  def self.create(...)
    new(...)
  end

  class << self
    private :new
  end

  def apply(rc)
    rc
  end
end
