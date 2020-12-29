module Orbital; end

class Orbital::Error < StandardError; end

class Orbital::CommandValidationError < Orbital::Error
  def initialize(msg, additional_info = nil)
    @additional_info = additional_info
    super(msg.to_flat_string)
  end

  attr_reader :additional_info
end

class Orbital::CommandUsageError < Orbital::Error; end
