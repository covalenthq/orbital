module Orbital; end

module Orbital::DeploymentRepoHelpers
  def ensure_up_to_date_deployment_repo
    return if self.ensure_cloned_deployment_repo

    logger.step "fast-forward appctl deployment repo"

    Dir.chdir(@context.application.deployment_worktree_root.to_s) do
      run 'git', 'fetch', 'upstream', '--tags', '--prune', '--prune-tags'

      upstream_branches = `git for-each-ref refs/heads --format="%(refname:short)"`.chomp.split("\n").sort

      # move default branch to the end, so it ends up staying checked out
      upstream_branches -= [@context.application.deployment_repo.default_branch]
      upstream_branches += [@context.application.deployment_repo.default_branch]

      upstream_branches.each do |branch|
        run 'git', 'checkout', '--quiet', branch
        run 'git', 'reset', '--hard', "upstream/#{branch}"
      end
    end
  end

  def ensure_cloned_deployment_repo
    return false if @context.application.deployment_worktree

    logger.step ["clone appctl deployment repo"]

    run 'git', 'clone', @context.application.deployment_repo.clone_uri, @context.application.deployment_worktree_root.to_s

    run(
      'git', 'remote', 'rename', 'origin', 'upstream',
      chdir: @context.application.deployment_worktree_root.to_s
    )

    true
  end
end
