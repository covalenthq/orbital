module Orbital; end
class Orbital::Class; end

class Orbital::Context::Machine
  def self.detect
    self.new
  end

  def platform
    return @platform if @platform
    require 'tty-platform'
    @platform = TTY::Platform.new
  end

  def inspect
    "#<Orbital/Machine>"
  end
end
