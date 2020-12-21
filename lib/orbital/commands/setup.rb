# frozen_string_literal: true

require 'orbital/command'
require 'orbital/converger'

module Orbital; end
module Orbital::Commands; end
class Orbital::Commands::Setup < Orbital::Command
  def initialize(options)
    @options = options
  end

  def execute(input: $stdin, output: $stdout)
    # ARGV currently contains ['setup'], so get rid of that
    ARGV.shift

    Rake.application = Orbital::Converger.new
    Rake.application.run
  end
end
