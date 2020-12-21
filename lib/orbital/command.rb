# frozen_string_literal: true

require 'forwardable'
require 'paint'
require 'orbital/errors'
require 'orbital/core_ext/to_flat_string'

module Orbital
  class Command
    extend Forwardable

    def sdk_root
      @sdk_root ||= Pathname.new(__dir__).parent.parent.expand_path
    end

    def project_root
      return @project_root if @project_root

      result = IO.popen(['git', 'rev-parse', '--show-toplevel'], err: [:child, :out]){ |io| io.read }

      fatal "command must be run within a git worktree" unless $?.success?

      @project_root = Pathname.new(result.strip).expand_path
    end

    def_delegators :command

    def fatal(*args)
      raise Orbital::CLI::FatalError.new(*args)
    end

    LOG_STYLES = {
      spawn: lambda{ |text| [Paint["$ ", :blue, :bold], Paint[text.to_flat_string, :blue]] },
      celebrate: lambda{ |text| ["🎉 ", Paint[text.to_flat_string, :bold]] },
      cry: lambda{ |text| ["😱 ", Paint[text, :bold, :red]] },
      step: lambda{ |text| ["\n", Paint["### ", :bold], Paint[text.to_flat_string, :bold]] },
      success: lambda{ |text| [Paint["✓", :green], " ", text] },
      failure: lambda{ |text| [Paint["✗", :red], " ", text] },
      warning: lambda{ |text| ["⚠️ ", Paint[text.to_flat_string, :yellow]] },
      info: lambda{ |text| [Paint["i ", :blue, :bold], text] },
      break: lambda{ |count| count ||= 1; "\n" * count }
    }

    def log(style, text = nil)
      formatter = LOG_STYLES[style]
      ansi = formatter.call(text)
      $stderr.puts(ansi.to_flat_string)
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

    def command(**options)
      require 'tty-command'
      TTY::Command.new(options)
    end

    def run(*cmdline, **kwargs)
      log :spawn, cmdline.join(' ')

      Kernel.system(*cmdline, **kwargs)

      unless $?.success?
        cmd_posix = Paint["#{cmdline[0]}(1)", :bold]
        fatal ["Nonzero exit status from ", cmd_posix]
      end
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
        log :success, "have #{cmd_posix_ref}"
      else
        fatal "#{cmd_posix_ref} is required. Please #{install_doc.to_flat_string}"
      end
    end
  end
end
