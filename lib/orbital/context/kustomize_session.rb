require 'kustomize/session'

module Orbital; end
class Orbital::Context; end

class Orbital::Context::KustomizeSession < Kustomize::Session
  attr_accessor :orbital_context

  def builtin_load_paths
    own_path = @orbital_context.sdk.root / 'lib' / 'orbital' / 'kustomize_plugins'

    [own_path] + super()
  end
end
