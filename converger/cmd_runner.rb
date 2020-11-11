require 'json'

class CmdRunner
  COLORS = {
    red: "\e[31m",
    green: "\e[32m",
    yellow: "\e[33m",
    blue: "\e[34m",
    bold: "\u001b[1m",
    reset: "\e[0m"
  }

  SYS_ERRS = Errno.constants.map do |err_name|
    e = Errno.const_get(err_name).exception
    [e.errno, {name: "#{err_name} (#{e.errno})", msg: e.message}]
  end.to_h

  def initialize
    @env = {}
  end

  def colorize(str, color)
    COLORS[color] + str + COLORS[:reset]
  end

  def with_env(env_patch)
    begin
      prev_env = @env
      @env = prev_env.merge(env_patch)
      yield
    ensure
      @env = prev_env
    end
  end

  def exit_with_code!(exit_code)
    sys_err = SYS_ERRS[exit_code] || {name: exit_code, msg: "Unknown error"}
    $stderr.puts(colorize("Failed with #{sys_err[:name]} -- #{sys_err[:msg]}", :red))
    Kernel.exit(exit_code)
  end

  def make_flags(kwargs, **kwarg_defaults)
    kwarg_defaults = kwargs.map{ |k, v| [k.to_s.tr('_', '-').intern, v.to_s] }.to_h
    kwargs = kwargs.map{ |k, v| [k.to_s.tr('_', '-').intern, v.to_s] }.to_h

    kwargs = kwarg_defaults.merge(kwargs)

    kwargs.map{ |k, v| "--#{k}=#{v}" }
  end

  def run_command!(*cmd, **kwargs)
    extra_flags = make_flags(kwargs)
    cmd = cmd.map(&:to_s) + extra_flags
    puts("\n=> " + colorize(cmd.join(' '), :green))
    system(@env, *cmd)
    exit_with_code!($?.exitstatus.to_i) unless $?.success?
  end

  def run_command_for_output!(*cmd, **kwargs)
    extra_flags = make_flags(kwargs)
    cmd = cmd.map(&:to_s) + extra_flags
    puts("\n** " + colorize(cmd.join(' '), :yellow))
    output = IO.popen(cmd){ |f| f.read }
    exit_with_code!($?.exitstatus.to_i) unless $?.success?
    output
  end

  def run_command_for_json!(*cmd, **kwargs)
    JSON.parse(self.run_command_for_output!(*cmd, **kwargs))
  end
end
