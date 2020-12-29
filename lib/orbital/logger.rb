require 'orbital/errors'
require 'orbital/escape_sequence_builder'

require 'orbital/core_ext/to_flat_string'

class Orbital::Logger
  def initialize(sink: $stderr)
    @sink = sink
    @last_header_buffer = nil
    @prev_step_emitted = false
    @using_cli = nil
  end

  def with_cli(cli)
    @using_cli = cli
  end

  def fatal(*args)
    raise Orbital::CommandValidationError.new(*args)
  end

  def step(ansi_desc)
    @last_header_buffer = ansi_desc
  end

  def break(num_lines = 1)
    self.emit ["\n" * num_lines]
  end

  def log(style, ansi_text)
    if @last_header_buffer
      if @prev_step_emitted
        self.break(1)
      else
        @prev_step_emitted = true
      end

      self.emit( self.styled(:step, @last_header_buffer) )
      @last_header_buffer = nil
    end

    self.emit( self.styled(style, ansi_text) )
  end

  def log_exception(e)
    case e
    when Orbital::Error
      self.break(1)
      self.emit( self.styled(:fatal, e.message) )

      if e_info = e.additional_info
        self.break(1)
        self.emit( self.styled(:info, e_info) )
      end
    else
      self.emit( e.message )
    end
  end

  def method_missing(method_name, *args)
    unless self.respond_to?(:"style_#{method_name}", true)
      return super
    end

    self.log(method_name, *args)
  end

  private

  def emit(ansi_text)
    @sink.write(ansi_text.to_flat_string)
    @sink.flush
  end

  def styled(style, msg_body)
    builder = Orbital::Logger::MessageBuilder.new
    self.send(:"style_#{style}", builder, msg_body)
  end

  def style_fatal(builder, msg_body)
    builder
    .text("🛑 ")
    .sgr{ |sgr| sgr.on(:bold) }
    .text(msg_body)
    .sgr{ |sgr| sgr.reset }
    .text("\n")
    .to_ansi
  end

  def style_spawn(builder, msg_body)
    builder
    .sgr{ |sgr| sgr.fg(:blue).on(:bold) }
    .text("$ ")
    .sgr{ |sgr| sgr.off(:bold) }
    .text(msg_body)
    .sgr{ |sgr| sgr.reset }
    .text("\n")
    .to_ansi
  end

  def style_cry(builder, msg_body)
    builder
    .text("😱 ")
    .sgr{ |sgr| sgr.fg(:red).on(:bold) }
    .text(msg_body)
    .sgr{ |sgr| sgr.reset }
    .text("\n")
    .to_ansi
  end

  def style_step(builder, msg_body)
    builder
    .sgr{ |sgr| sgr.on(:bold) }
    .text("### ")
    .text(msg_body)
    .sgr{ |sgr| sgr.reset }
    .text("\n")
    .to_ansi
  end

  def style_success(builder, msg_body)
    builder
    .sgr{ |sgr| sgr.fg(:green) }
    .text("✓ ")
    .sgr{ |sgr| sgr.fg(:default) }
    .text(msg_body)
    .sgr{ |sgr| sgr.reset }
    .text("\n")
    .to_ansi
  end

  def style_failure(builder, msg_body)
    builder
    .sgr{ |sgr| sgr.fg(:red) }
    .text("✗ ")
    .sgr{ |sgr| sgr.fg(:default) }
    .text(msg_body)
    .sgr{ |sgr| sgr.reset }
    .text("\n")
    .to_ansi
  end

  def style_warning(builder, msg_body)
    builder
    .text("⚠️ ")
    .sgr{ |sgr| sgr.fg(:yellow) }
    .text(msg_body)
    .sgr{ |sgr| sgr.reset }
    .text("\n")
    .to_ansi
  end

  def style_info(builder, msg_body)
    builder
    .sgr{ |sgr| sgr.fg(:blue).on(:bold) }
    .text("i ")
    .sgr{ |sgr| sgr.fg(:default).off(:bold) }
    .text(msg_body)
    .sgr{ |sgr| sgr.reset }
    .text("\n")
    .to_ansi
  end
end

class Orbital::Logger::MessageBuilder
  def initialize
    @ansi = []
  end

  def text(text)
    @ansi << text
    self
  end

  def sgr(&block)
    seq_builder = Orbital::EscapeSequenceBuilder.new
    seq_builder.sgr(&block)
    @ansi << seq_builder.to_ansi
    self
  end

  def to_ansi
    @ansi
  end
end
