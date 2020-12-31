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
      @deferred_cleanups = {}
      @deferred_cleanups_order = []
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

    def defer_cleanup(cleanup_key, &cleanup_proc)
      @deferred_cleanups[cleanup_key] = cleanup_proc
      @deferred_cleanups_order << cleanup_key
    end

    def cancel_cleanup
      @deferred_cleanups.delete(cleanup_key)
      @deferred_cleanups_order.delete(cleanup_key)
    end

    def execute_deferred_cleanups
      deferred_procs =
        @deferred_cleanups_order
        .reverse
        .map{ |k| @deferred_cleanups[k] }
        .filter{ |v| v }

      unless deferred_procs.empty?
        self.logger.step "cleaning up"
      end

      deferred_procs.each(&:call)
    end


    def cursor
      require 'tty-cursor'
      TTY::Cursor
    end

    def editor
      require 'tty-editor'
      TTY::Editor
    end

    def generator
      require 'tty-file'
      TTY::File
    end

    def link_to(uri, text)
      require 'tty-link'
      TTY::Link.link_to(text, uri)
    end

    def pager(**options)
      require 'tty-pager'
      TTY::Pager.new(options)
    end

    def prompt(**options)
      require 'tty-prompt'
      TTY::Prompt.new(options)
    end

    def screen
      require 'tty-screen'
      TTY::Screen
    end

    def which(*args)
      require 'tty-which'
      TTY::Which.which(*args)
    end

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
