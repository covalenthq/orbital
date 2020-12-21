# frozen_string_literal: true

require 'pathname'
require 'orbital/command'
require 'orbital/errors'

module Orbital; end
module Orbital::Commands; end
class Orbital::Commands::Update < Orbital::Command
  def initialize(options)
    @options = options
  end

  def execute(input: $stdin, output: $stdout)
    # can be a directory, or a file if `git worktree add` is used
    git_path = self.sdk_root / '.git'

    unless git_path.exist?
      fatal "Orbital SDK project root is not a git worktree!"
    end

    Dir.chdir(self.sdk_root.to_s) do
      on_branch = `git branch --show-current`.strip

      unless on_branch == 'master'
        fatal "Orbital SDK worktree is not on master branch"
      end

      unless `git status --porcelain`.strip.empty?
        fatal "Orbital SDK worktree is dirty"
      end

      system('git', 'fetch', 'origin')
      system('git', 'reset', '--hard', 'origin/master')
    end
  end
end
