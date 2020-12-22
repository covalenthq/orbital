module Orbital
  class Error < StandardError; end

  class CommandValidationError < Error
    def initialize(msg, additional_info = nil)
      @additional_info = additional_info
      super(msg.to_flat_string)
    end

    attr_reader :additional_info
  end
end
