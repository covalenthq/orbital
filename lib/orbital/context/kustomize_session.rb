require 'kustomize/session'

module Orbital; end
class Orbital::Context; end

class Orbital::Context::KustomizeSession < Kustomize::Session
  def initialize(context)
    @context = context
  end

  def load_paths
    return @load_paths if @load_paths
    @load_paths = [
      self.sdk_load_path,
      self.project_load_path
    ].compact
  end

  def sdk_load_path
    @sdk_load_path ||= @context.sdk.root / 'lib' / 'orbital' / 'kustomize_plugins'
  end

  def project_load_path
    return @project_load_path if @probed_project_load_path

    maybe_lp = @context.project.root / '.orbital' / 'kustomize-plugins'

    @project_load_path = (maybe_lp.directory?) ? maybe_lp : nil

    @probed_project_load_path = true

    @project_load_path
  end
end
