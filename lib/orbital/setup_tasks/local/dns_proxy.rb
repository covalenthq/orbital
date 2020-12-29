# frozen_string_literal: true

require 'orbital/setup_task'

module Orbital; end
module Orbital::SetupTasks; end
module Orbital::SetupTasks::Local; end
class Orbital::SetupTasks::Local::InstallDNSProxy < Orbital::SetupTask
  dependent_on :brew

  NETWORK_SERVICE_UUID = "2bd811f4-95b4-4cd4-9086-a9fa7c870b68"

  def dnsmasq_conf_path
    Pathname.new('/usr/local/etc/dnsmasq.conf')
  end

  def dnsmasq_conf_dir
    Pathname.new('/usr/local/etc/dnsmasq.d')
  end

  def cluster_dns_conf_path
    self.dnsmasq_conf_dir / 'local-k8s-cluster.conf'
  end

  def resolved?
    self.cluster_dns_conf_path.file?
  end

  def validate_own_environment!
    unless @context.platform.mac?
      raise NotImplementedError, "local DNS proxy setup only implemented on macOS"
    end
  end

  def execute(*)
    dnsmasq_conf_path = Pathname.new('/usr/local/etc/dnsmasq.conf')
    dnsmasq_conf_dir = Pathname.new('/usr/local/etc/dnsmasq.d')
    cluster_dns_conf_path = dnsmasq_conf_dir / 'local-k8s-cluster.conf'

    unless exec_exist? 'dnsmasq'
      logger.step "install dnsmasq"
      run 'brew', 'install', 'dnsmasq'
    end

    logger.step "configure dnsmasq to forward to in-cluster resolver"
    dnsmasq_conf_dir.mkpath

    import_ln = "conf-dir=#{dnsmasq_conf_dir}/,*.conf\n"
    unless dnsmasq_conf_path.readlines.include?(import_ln)
      dnsmasq_conf_path.open('a'){ |f| f.write(import_ln) }
    end

    cluster_dns_conf_path.open('w') do |f|
      # for external cluster access
      f.puts 'no-resolv'
      f.puts 'no-poll'
      f.puts 'address=/.localhost/127.0.0.1'

      # fixes a bug with Docker on Mac's k8s
      f.puts 'address=/localhost.localdomain/127.0.0.1'
    end

    logger.step "start dnsmasq service"
    run 'sudo', 'brew', 'services', 'restart', 'dnsmasq'

    logger.step "add dnsmasq to OS DNS resolution chain"
    IO.popen(['sudo', 'scutil'], 'r+') do |scutil|
      scutil.puts 'd.init'
      scutil.puts 'd.add ServerAddresses * 127.0.0.1'
      scutil.puts 'd.add SupplementalMatchDomains * k8s.localhost'
      scutil.puts "set State:/Network/Service/#{NETWORK_SERVICE_UUID}/DNS"
      scutil.close
    end
  end
end
