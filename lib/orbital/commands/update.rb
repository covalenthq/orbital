# frozen_string_literal: true

require 'pathname'
require_relative '../command'
require 'orbital/errors'

module Orbital
  module Commands
    class Update < Orbital::Command
      def initialize(options)
        @options = options
        @project_root = Pathname.new(__dir__).parent.parent.parent.expand_path
      end

      def execute(input: $stdin, output: $stdout)
        # can be a directory, or a file if `git worktree add` is used
        git_path = @project_root / '.git'

        unless git_path.exist?
          raise Orbital::CLI::Error, "Orbital SDK project root is not a git worktree!"
        end

        Dir.chdir(@project_root.to_s) do
          on_branch = `git branch --show-current`.strip

          unless on_branch == 'master'
            raise Orbital::CLI::Error, "Orbital SDK worktree is not on master branch"
          end

          unless `git status --porcelain`.strip.empty?
            raise Orbital::CLI::Error, "Orbital SDK worktree is dirty"
          end

          system('git', 'fetch', 'origin')
          system('git', 'reset', '--hard', 'origin/master')
        end
      end
    end
  end
end
