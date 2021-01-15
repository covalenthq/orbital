module Kustomize; end

require 'kustomize/plugin_manager'

class Kustomize::Session
  def plugin_manager
    return @plugin_manager if @plugin_manager
    @plugin_manager = Kustomize::PluginManager.new(session: self)
  end

  def load_paths
    return @load_paths if @load_paths
    @load_paths = [
      Pathname.new(__FILE__).expand_path.parent / 'plugin'
    ]
  end
end
