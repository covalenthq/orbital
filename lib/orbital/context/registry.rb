require 'singleton'
require 'securerandom'

module Orbital; end
class Orbital::Context; end

class Orbital::Context::Registry
  include Singleton

  def initialize
    @instances = {}
  end

  def register(inst)
    return false if inst.uuid
    inst.uuid = SecureRandom.uuid.intern
    @instances[inst.uuid] = inst
    true
  end

  def fetch_instance(uuid)
    uuid = uuid.to_s.intern unless uuid.kind_of?(Symbol)

    unless @instances.has_key?(uuid)
      raise KeyError, "no Orbital instance registered with uuid #{uuid}"
    end

    @instances[uuid]
  end
end
