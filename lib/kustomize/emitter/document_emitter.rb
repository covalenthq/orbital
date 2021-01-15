require 'kustomize/emitter'

class Kustomize::Emitter::DocumentEmitter < Kustomize::Emitter
  def self.load(doc, source:, session:)
    self.new(doc, source: source, session: session)
  end

  def initialize(doc, source: nil, session:)
    @session = session

    @doc = doc
    @source = source
  end

  def emit
    [@doc]
  end
end
