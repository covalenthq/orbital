require 'orbital/spinner'
require 'orbital/ext/core/to_flat_string'

module Orbital; end
class Orbital::Spinner::PollingSpinner < Orbital::Spinner
  def initialize(poll_interval: 1.0, **kwargs)
    @poll_interval = poll_interval
    @poll_attempts = 0
    super(**kwargs)
  end

  def resolve
    last_probe_time = Time.at(0)

    while true
      tick_time = Time.now

      if (tick_time - last_probe_time) >= @poll_interval
        @result = self.poll
        @poll_attempts += 1
        last_probe_time = Time.now
      end

      if self.resolved?
        break
      end

      Kernel.sleep(0.1 + rand(0.2))
    end
  end

  def poll
    Kernel.sleep(1.0)
    if @poll_attempts >= 4
      :ok
    else
      nil
    end
  end

  def state
    case @result
    when :ok
      :success
    when nil
      if @poll_attempts > 0
        :in_progress
      else
        :queued
      end
    end
  end

  def resolved?
    not(@result.nil?)
  end
end

class Orbital::Spinner::SimplePollingSpinner < Orbital::Spinner::PollingSpinner
  def initialize(poll: nil, accept: nil, **kwargs)
    super(**kwargs)
    @poll_fn = poll
    @accept_fn = accept
  end

  def poll
    @poll_fn.call(@result)
  end

  def state
    if @accept_fn.call(@result)
      :success
    elsif @poll_attempts > 0
      :in_progress
    else
      :queued
    end
  end

  def resolved?
    not([:in_progress, :queued].include?(self.state))
  end
end
