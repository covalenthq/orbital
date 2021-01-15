module Kustomize; end

class Kustomize::Emitter
  def input_emitters; []; end

  def input_resources
    self.input_emitters.flat_map(&:emit)
  end

  def emit
    self.input_resources
  end

  def to_yaml_stream
    self.emit.map(&:to_yaml).join("")
  end
end
