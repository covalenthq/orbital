module Orbital; end

class Orbital::Error < StandardError; end

class Orbital::CommandValidationError < Orbital::Error
  def initialize(msg, additional_info = nil)
    @additional_info = additional_info

    msg =
      if msg.respond_to?(:to_flat_string)
        msg.to_flat_string
      else
        msg.to_s
      end

    super(msg)
  end

  attr_reader :additional_info
end

class Orbital::CommandUsageError < Orbital::Error; end
