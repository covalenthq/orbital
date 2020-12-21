module Orbital; end
class Orbital::Spinner; end

class Orbital::Spinner::Animation
  STYLES = {
    working: {
      interval: 1,
      frames: ['⣾', '⣽', '⣻', '⢿', '⡿', '⣟', '⣯', '⣷']
    },
    waiting: {
      interval: 3,
      frames: ['⠒', '⠂', ' ', '⠂', '⠒', '⠐', ' ', '⠐']
    }
  }

  def initialize(style)
    @frames = STYLES[style][:frames]
    @interval = STYLES[style][:interval]
    @step = 0
    @frame = 0
  end

  def to_s
    @frames[@frame]
  end

  def tick
    @step += 1

    while @step >= @interval
      @frame = (@frame + 1) % @frames.length
      @step -= @interval
    end
  end
end
