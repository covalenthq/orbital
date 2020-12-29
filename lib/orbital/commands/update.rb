# frozen_string_literal: true

require 'pathname'
require 'orbital/command'
require 'orbital/errors'

module Orbital; end
module Orbital::Commands; end
class Orbital::Commands::Update < Orbital::Command
  def validate_environment!
    return if @validated_environment
    logger.step "ensure shell environment is sane for update"

    @context.validate :sdk_is_git_worktree do
      unless @context.sdk.git_worktree?
        logger.fatal "Orbital SDK project root is not a git worktree!"
      end
    end

    @context.validate :sdk_worktree_clean do
      if @context.sdk.worktree_clean?
        logger.success "Orbital SDK worktree is clean"
      else
        logger.fatal "Orbital SDK worktree is dirty"
      end
    end

    @context.validate :git_worktree_is_on_master_branch do
      Dir.chdir(@context.sdk.root.to_s) do
        on_branch = `git branch --show-current`.strip

        unless on_branch == 'master'
          logger.fatal "Orbital SDK worktree is not on master branch"
        end
      end
      logger.success "Orbital SDK worktree is on master branch"
    end

    @validated_environment = true
  end

  def execute(input: $stdin, output: $stdout)
    self.validate_environment!

    logger.step "Updating Orbital SDK worktree"
    Dir.chdir(@context.sdk.root.to_s) do
      system('git', 'fetch', 'origin')
      system('git', 'reset', '--hard', 'origin/master')
    end
  end
end
