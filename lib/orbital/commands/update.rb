# frozen_string_literal: true

require 'pathname'
require 'orbital/command'
require 'orbital/errors'

module Orbital; end
module Orbital::Commands; end
class Orbital::Commands::Update < Orbital::Command
  def validate_environment!
    return if @validated_environment
    log :step, "ensure shell environment is sane for update"

    @environment.validate :sdk_is_git_worktree do
      unless @environment.sdk.git_worktree?
        fatal "Orbital SDK project root is not a git worktree!"
      end
    end

    @environment.validate :sdk_worktree_clean do
      if @environment.sdk.worktree_clean?
        log :success, "Orbital SDK worktree is clean"
      else
        fatal "Orbital SDK worktree is dirty"
      end
    end

    @environment.validate :git_worktree_is_on_master_branch do
      Dir.chdir(@environment.sdk.root.to_s) do
        on_branch = `git branch --show-current`.strip

        unless on_branch == 'master'
          fatal "Orbital SDK worktree is not on master branch"
        end
      end
      log :success, "Orbital SDK worktree is on master branch"
    end

    @validated_environment = true
  end

  def execute(input: $stdin, output: $stdout)
    self.validate_environment!

    log :step, "Updating Orbital SDK worktree"
    Dir.chdir(@environment.sdk.root.to_s) do
      system('git', 'fetch', 'origin')
      system('git', 'reset', '--hard', 'origin/master')
    end
  end
end
