require 'kustomize/emitter'

class Kustomize::Emitter::PluginEmitter < Kustomize::Emitter
  def initialize(input_emitter, session:)
    @session = session
    @input_emitter = input_emitter
  end

  def source_directory
    @source_path.parent
  end

  def input_emitters
    [@input_emitter]
  end

  def plugin_instances
    return @plugin_instances if @plugin_instances

    @plugin_instances =
      self.input_resources.map do |rc|
        plugin_klass = @session.plugin_manager.get(rc['apiVersion'], rc['kind'])
        plugin_klass.new(rc)
      end
  end

  def emit
    self.plugin_instances.flat_map(&:emit)
  end
end
