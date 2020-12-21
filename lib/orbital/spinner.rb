require 'paint'

require 'orbital/spinner/animation'
require 'orbital/core_ext/to_flat_string'

module Orbital; end
class Orbital::Spinner
  def initialize(wait_text: "Waiting", done_text: nil)
    @wait_text = wait_text
    @done_text = done_text || wait_text

    @animations = [:working, :waiting].map{ |anim_name|
      [anim_name, Orbital::Spinner::Animation.new(anim_name)]
    }.to_h

    @result = nil
  end

  attr_reader :result

  def resolve
    Kernel.sleep(5.0)
    @result = true
  end

  def state
    @result ? :success : :in_progress
  end

  def format_with_state(state, str)
    case state
    when :success
      [Paint["✓", :green], " ", str]
    when :success_pointless
      [Paint["✓", :yellow], " ", str]
    when :failure
      [Paint["✘", :red], " ", str]
    when :skipped
      [Paint["↯", :yellow], " ", "\e[9m", str, "\e[0m"]
    when :in_progress
      [Paint[@animations[:working].to_s, :blue], " ", str, "…"]
    when :queued
      Paint[[@animations[:waiting].to_s, " ", str].to_flat_string, [192, 192, 192]]
    end
  end

  def draw(mode)
    case mode
    when :spinning
      $stdout.write(["\r", format_with_state(self.state, @wait_text)].to_flat_string)
    when :done
      $stdout.puts(["\r\e[K", format_with_state(self.state, @done_text)].to_flat_string)
    end
  end

  def run
    @started_at = Time.now

    resolver_thread = Thread.new{ self.resolve }

    while true
      break unless resolver_thread.status
      self.draw(:spinning)
      @animations.each{ |_, anim| anim.tick }
      Kernel.sleep(0.1)
    end

    self.draw(:done)

    self
  end
end
