# frozen_string_literal: true

require_relative '../command'
require_relative '../converger'

module Orbital
  module Commands
    class Setup < Orbital::Command
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
  end
end
