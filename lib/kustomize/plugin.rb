module Kustomize; end

class Kustomize::Plugin
  def initialize(rc)
    @rc = rc
  end

  def emit
    raise NotImplementedError, "Kustomize plugins must implement #emit"
  end
end
