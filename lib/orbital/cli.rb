# frozen_string_literal: true

require 'thor'

require 'orbital'

class Orbital::CommandRouter < Thor; end
class Orbital::CLI < Orbital::CommandRouter; end
class Orbital::CLI::SetupSubcommand < Orbital::CommandRouter; end
class Orbital::CLI::LocalSetupSubcommand < Orbital::CommandRouter; end
class Orbital::CLI::ClusterSetupSubcommand < Orbital::CommandRouter; end

class Orbital::CommandRouter < Thor
  def self.start(*args)
    # `cli command -h` does not work without the following, except for subcommands...
    # Ref: https://stackoverflow.com/a/49044225/6431461
    if (Thor::HELP_MAPPINGS & ARGV).any? && subcommands.grep(/^#{ARGV[0]}/).empty?
      Thor::HELP_MAPPINGS.each do |cmd|
        if (match = ARGV.delete(cmd))
          ARGV.unshift match
        end
      end
    end
    super
  end

  def self.banner(command, namespace = nil, subcommand = false)
    full_prefix = [basename, subcommand_prefix].filter{ |x| x && not(x.empty?) }.join(' ')
    "#{full_prefix} #{command.usage}"
  end

  def self.subcommand_prefix
    self.name.gsub(%r{.*::}, '').gsub(%r{^[A-Z]}) { |match| match[0].downcase }.gsub(%r{[A-Z]}) { |match| "-#{match[0].downcase}" }
  end

  def self.exit_on_failure?
    false
  end
end

class Orbital::CLI < Orbital::CommandRouter
  # class_option :help, aliases: '-h', type: :boolean, hide: true

  def self.subcommand_prefix; ""; end

  class_option :contextuuid, type: :string, required: true, hide: true

  desc 'version', 'Print the Orbital SDK version'
  def version
    require 'orbital/version'
    puts "v#{Orbital::VERSION}"
  end
  map %w(--version -v) => :version

  desc 'trigger', 'Trigger Github Actions workflows for project'
  method_option :repo, aliases: '-r', type: :string,
                       desc: "Repo to target (app, deployment, or \"username/reponame\")"
  method_option :branch, aliases: '-b', type: :string,
                         desc: "Branch of repo that workflow-runner will run in"
  method_option :workflow, aliases: '-w', type: :string, required: true,
                           desc: "Name of workflow to run"
  method_option :input, aliases: '-i', type: :array,
                        desc: "Set a workflow input (format KEY=VALUE)"
  def trigger(*)
    return invoke(:help, [:trigger]) if options[:help]
    require 'orbital/commands/trigger'
    Orbital::Commands::Trigger.new(self, options).execute
  end

  desc 'update', 'Update the Orbital SDK'
  def update(*)
    return invoke(:help, [:trigger]) if options[:help]
    require 'orbital/commands/update'
    Orbital::Commands::Update.new(self, options).execute
  end

  desc 'setup', 'Run dev-toolchain and k8s-cluster setup workflows'
  subcommand 'setup', Orbital::CLI::SetupSubcommand

  desc 'release', 'Burn a tagged release commit, and build an image from it'
  method_option :imagebuilder, aliases: '-i', type: :string, banner: 'STRATEGY',
                               enum: ['docker', 'github', 'cloudbuild'], default: 'docker',
                               desc: "Build Docker image with the given strategy."
  method_option :deploy, aliases: '-d', type: :boolean, default: false,
                       desc: "Automatically deploy if release succeeds."
  method_option :deployer, aliases: '-D', type: :string, banner: 'STRATEGY',
                           enum: ['appctl', 'github', 'internal'], default: 'appctl',
                           desc: "Deploy with the given strategy."
  method_option :wait, aliases: '-w', type: :boolean, default: true,
                       desc: "Wait for k8s state to converge."
  def release(*)
    return invoke(:help, [:trigger]) if options[:help]
    require 'orbital/commands/release'
    Orbital::Commands::Release.new(self, options).execute
  end

  desc 'deploy', 'Push a release to a k8s appctl(1) environment'
  method_option :tag, aliases: '-t', type: :string, required: true,
                      desc: "Release tag to deploy."
  method_option :env, aliases: '-e', type: :string, default: "staging",
                      desc: "appctl(1) environment to target."
  method_option :deployer, aliases: '-D', type: :string, banner: 'STRATEGY',
                           enum: ['appctl', 'github', 'internal'], default: 'appctl',
                           desc: "Deploy with the given strategy."
  method_option :wait, aliases: '-w', type: :boolean, default: true,
                       desc: "Wait for k8s state to converge."
  def deploy(*)
    return invoke(:help, [:trigger]) if options[:help]
    require 'orbital/commands/deploy'
    Orbital::Commands::Deploy.new(self, options).execute
  end
end

class Orbital::CLI::SetupSubcommand < Orbital::CommandRouter
  def self.subcommand_prefix; 'setup'; end

  class_option :cluster, aliases: '-c', type: :string, banner: 'TYPE',
                     enum: ['local', 'gcloud'], default: 'local',
                     desc: "Specify a Kubernetes cluster to target."

  desc 'local', 'Run dev-toolchain setup workflows'
  subcommand 'local', Orbital::CLI::LocalSetupSubcommand

  desc 'cluster', 'Run k8s-cluster setup workflows'
  subcommand 'cluster', Orbital::CLI::ClusterSetupSubcommand
end

class Orbital::CLI::LocalSetupSubcommand < Orbital::CommandRouter
  def self.subcommand_prefix; 'setup local'; end

  desc 'ca-cert', 'Create and install a local trusted Certificate Authority'
  def ca_cert(*)
    return invoke(:help, [:trigger]) if options[:help]
    require 'orbital/setup_tasks/local/ca_cert'
    Orbital::SetupTasks::Local::InstallCACert.new(self, options).execute_tree
  end

  desc 'dns-proxy', 'Install a proxy forwarding to an in-cluster DNS resolver'
  def dns_proxy(*)
    return invoke(:help, [:trigger]) if options[:help]
    require 'orbital/setup_tasks/local/dns_proxy'
    Orbital::SetupTasks::Local::InstallDNSProxy.new(self, options).execute_tree
  end

  desc 'helm-repos', 'Register and sync required Helm repositories'
  def helm_repos(*)
    return invoke(:help, [:trigger]) if options[:help]
    require 'orbital/setup_tasks/local/helm_repos'
    Orbital::SetupTasks::Local::SyncHelmRepos.new(self, options).execute_tree
  end
end

class Orbital::CLI::ClusterSetupSubcommand < Orbital::CommandRouter
  def self.subcommand_prefix; 'setup cluster'; end

  desc 'namespaces', 'Register core k8s namespaces'
  def namespaces(*)
    return invoke(:help, [:trigger]) if options[:help]
    require 'orbital/setup_tasks/cluster/namespaces'
    Orbital::SetupTasks::Cluster::CreateNamespaces.new(self, options).execute_tree
  end

  desc 'ingress-controller', 'Install Nginx + cert issuers into the cluster'
  def ingress_controller(*)
    return invoke(:help, [:trigger]) if options[:help]
    require 'orbital/setup_tasks/cluster/ingress_controller'
    Orbital::SetupTasks::Cluster::InstallIngressController.new(self, options).execute_tree
  end
end
