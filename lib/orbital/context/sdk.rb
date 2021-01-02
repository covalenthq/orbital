module Orbital; end
class Orbital::Context; end

class Orbital::Context::SDK
  def initialize(root)
    @root = root
  end

  attr_accessor :environment

  attr_reader :root


  INSTALL_PREFIX_SIGNATURE_DIRS = %w(bin etc share var libexec)

  def installed?
    not(self.install_prefix.nil?)
  end

  def git_worktree?
    # can be a directory, or a file if `git worktree add` is used
    (@root / '.git').exist?
  end

  def worktree_clean?
    return @worktree_clean if @probed_worktree_clean
    return false unless self.git_worktree?

    @probed_worktree_clean = true
    Dir.chdir(@root.to_s) do
      @worktree_clean = `git status --porcelain`.strip.empty?
    end
  end

  def install_prefix
    return @install_prefix if @probed_install_prefix
    @probed_install_prefix = true

    maybe_prefix = @root.parent.parent

    @install_prefix =
      if INSTALL_PREFIX_SIGNATURE_DIRS.find{ |d_name| (maybe_prefix / d_name).directory? }
        maybe_prefix
      end
  end

  def state_dir
    return @state_dir if @state_dir

    @state_dir =
      if prefix = self.install_prefix
        prefix / 'var' / 'lib' / 'orbital'
      else
        @root / 'var'
      end
  end

  def k8s_resource_configs_dir
    @root / 'share' / 'setup' / 'resources'
  end

  def inspect
    "#<Orbital/SDK root=#{@root.to_s.inspect}>"
  end
end
