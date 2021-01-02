# frozen_string_literal: true

require 'pry'

require 'orbital/command'

module Orbital; end
module Orbital::Commands; end
class Orbital::Commands::Console < Orbital::Command
  def execute
    Pry.start(@context.get_binding, quiet: true)
  end
end
