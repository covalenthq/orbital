class Orbital::EscapeSequenceBuilder
  def initialize
    @sequences = []
  end

  def sgr(&block)
    sgr_builder = SGRBuilder.new
    block.call(sgr_builder)
    if sgr_seq = sgr_builder.sequence
      @sequences << sgr_seq
    end
    self
  end

  def to_ansi
    @sequences.flat_map(&:to_ansi)
  end
end

class Orbital::EscapeSequenceBuilder::Sequence
  def initialize(prefix:, suffix:, params: [])
    @prefix_code = prefix
    @suffix_code = suffix
    @params = params
  end

  def <<(param_code)
    @params << param_code
  end

  def to_ansi
    ["\e", @prefix_code, @params.map(&:to_s).join(";"), @suffix_code]
  end
end

class Orbital::EscapeSequenceBuilder::SGRBuilder
  def initialize
    @params = []
  end

  def sequence
    return nil if @params.empty?
    Orbital::EscapeSequenceBuilder::Sequence.new(
      prefix: '[',
      suffix: 'm',
      params: @params
    )
  end

  def reset
    @params << 0
    self
  end

  def fg(value)
    @params += fg_color_code(value)
    self
  end

  def bg(value)
    @params += bg_color_code(value)
    self
  end

  def font(value)
    @params << font_code(value)
    self
  end

  def on(value)
    @params << EFFECT_ENABLE_CODES[value]
    self
  end

  def off(value)
    @params << EFFECT_DISABLE_CODES[value]
    self
  end

  private

  EFFECT_ENABLE_CODES = {
    bright: 1,
    bold: 1,
    faint: 2,
    italic: 3,
    underline: 4,
    blink: 5,
    rapid_blink: 6,
    inverse: 7,
    conceal: 8,
    strikethrough: 9,
    fraktur: 20,
    frame: 51,
    encircle: 52,
    overline: 53,
  }

  EFFECT_DISABLE_CODES = {
    bright: 21,
    bold: 21,
    faint: 22,
    italic: 23,
    underline: 24,
    blink: 25,
    rapid_blink: 25,
    inverse: 26,
    conceal: 27,
    strikethrough: 29,
    fraktur: 23,
    frame: 54,
    encircle: 54,
    overline: 55
  }

  ANSI_COLOR_CODES = {
    black: 0,
    red: 1,
    green: 2,
    yellow: 3,
    blue: 4,
    magenta: 5,
    cyan: 6,
    white: 7,
    default: 9
  }

  def fg_color_code(o)
    case o
    when Symbol
      [30 + ANSI_COLOR_CODES[o]]
    when Color::RGB
      [38, 2, color.red.round, color.green.round, color.blue.round]
    end
  end

  def bg_color_code(o)
    case o
    when Symbol
      [40 + ANSI_COLOR_CODES[o]]
    when Color::RGB
      [48, 2, color.red.round, color.green.round, color.blue.round]
    end
  end

  def font_code(o)
    if o == :default
      10
    elsif o.kind_of?(Integer)
      10 + font_offset
    end
  end
end
