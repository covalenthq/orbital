require 'pathname'

module Orbital; end
class Orbital::Context; end

class Orbital::Context::Shell
  def initialize(env)
    @env = env
    @homedir = Pathname.new(env['HOME'])
  end

  attr_accessor :environment

  attr_reader :homedir

  def xdg_prefix
    return @xdg_prefix if @xdg_prefix

    @xdg_prefix =
      if xdg_data_home = @env['XDG_DATA_HOME']
        Pathname.new(xdg_data_home).parent
      else
        @homedir / '.local'
      end
  end

  def kubectl_config_path
    @homedir / '.kube' / 'config'
  end
end
