# frozen_string_literal: true

require 'paint'
require 'recursive-open-struct'

require 'orbital'
require 'orbital/context'

module Orbital
  class Command
    def initialize(cli, options, ctx = nil)
      options = options.dup

      @context = ctx || Orbital::Context.lookup(options.delete(:contextuuid))
      @cli = cli

      @options = RecursiveOpenStruct.new(options, recurse_over_arrays: true)
    end

    def sibling_command(command_klass, **options)
      command_klass.new(@cli, options, @context)
    end

    attr_accessor :options

    def logger
      @context.logger
    end

    # Execute this command
    #
    # @api public
    def execute(*)
      raise(
        NotImplementedError,
        "#{self.class}##{__method__} must be implemented"
      )
    end

    def run(*cmdline, **kwargs)
      logger.spawn cmdline.join(' ')

      capturing_output = kwargs.delete(:capturing_output)
      fail_ok = kwargs.delete(:fail_ok)

      result =
        if capturing_output
          IO.popen(cmdline, **kwargs) { |f| f.read }
        else
          Kernel.system(*cmdline, **kwargs)
        end

      unless fail_ok || $?.success?
        cmd_posix = Paint["#{cmdline[0]}(1)", :bold]
        logger.fatal ["Nonzero exit status from ", cmd_posix]
      end

      result
    end

    # The cursor movement
    #
    # @see http://www.rubydoc.info/gems/tty-cursor
    #
    # @api public
    def cursor
      require 'tty-cursor'
      TTY::Cursor
    end

    # Open a file or text in the user's preferred editor
    #
    # @see http://www.rubydoc.info/gems/tty-editor
    #
    # @api public
    def editor
      require 'tty-editor'
      TTY::Editor
    end

    # File manipulation utility methods
    #
    # @see http://www.rubydoc.info/gems/tty-file
    #
    # @api public
    def generator
      require 'tty-file'
      TTY::File
    end

    def link_to(uri, text)
      require 'tty-link'
      TTY::Link.link_to(text, uri)
    end

    # Terminal output paging
    #
    # @see http://www.rubydoc.info/gems/tty-pager
    #
    # @api public
    def pager(**options)
      require 'tty-pager'
      TTY::Pager.new(options)
    end

    # Terminal platform and OS properties
    #
    # @see http://www.rubydoc.info/gems/tty-pager
    #
    # @api public
    def platform
      require 'tty-platform'
      TTY::Platform.new
    end

    # The interactive prompt
    #
    # @see http://www.rubydoc.info/gems/tty-prompt
    #
    # @api public
    def prompt(**options)
      require 'tty-prompt'
      TTY::Prompt.new(options)
    end

    # Get terminal screen properties
    #
    # @see http://www.rubydoc.info/gems/tty-screen
    #
    # @api public
    def screen
      require 'tty-screen'
      TTY::Screen
    end

    # The unix which utility
    #
    # @see http://www.rubydoc.info/gems/tty-which
    #
    # @api public
    def which(*args)
      require 'tty-which'
      TTY::Which.which(*args)
    end

    # Check if executable exists
    #
    # @see http://www.rubydoc.info/gems/tty-which
    #
    # @api public
    def exec_exist?(*args)
      require 'tty-which'
      TTY::Which.exist?(*args)
    end

    def exec_exist!(cmd_name, install_doc)
      cmd_posix_ref = Paint["#{cmd_name}(1)", :bold]

      if self.exec_exist?(cmd_name)
        logger.success "have #{cmd_posix_ref}"
      else
        logger.fatal "#{cmd_posix_ref} is required. Please #{install_doc.to_flat_string}"
      end
    end
  end
end
