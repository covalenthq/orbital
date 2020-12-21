# frozen_string_literal: true

require 'paint'
require 'pathname'
require 'yaml'
require 'json'
require 'ostruct'
require 'singleton'
require 'uri'
require 'set'

require 'orbital/command'
require 'orbital/spinner/polling_spinner'
require 'orbital/core_ext/to_flat_string'

module Orbital; end
module Orbital::Commands; end
class Orbital::Commands::Deploy < Orbital::Command
  def initialize(options)
    @options = OpenStruct.new(options)

    appctl_config_path = self.project_root / '.appctlconfig'

    unless appctl_config_path.file?
      fatal "orbital-deploy must be run under a Git worktree containing an .appctlconfig"
    end

    @appctl_config = YAML.load(appctl_config_path.read)
    @deployment_worktree_root = self.project_root / @appctl_config['deploy_repo_path']
  end

  def tag=(new_tag)
    @options.tag = new_tag
  end

  def app_name
    @appctl_config['application_name']
  end

  def target_environments
    return @target_environments if @target_environments

    appctl_envs_path = @deployment_worktree_root / 'environments.yaml'

    unless appctl_envs_path.file?
      fatal "deployment repo has not yet been cloned"
    end

    @target_environments = YAML.load(appctl_envs_path.read)['envs'].map{ |e| [e['name'], e] }.to_h
  end

  def validate_environment
    return if @environment_validated

    log :step, "ensure deploy environment is sane"

    gcloud_install_doc = [link_to(
      "https://cloud.google.com/sdk/docs/install",
      "install the Google Cloud SDK."
    ), '.']

    if @options.wait
      kubectl_install_doc = if exec_exist? 'gcloud'
        ["run:\n", "  ", Paint["gcloud components install kubectl", :bold]]
      else
        gcloud_install_doc
      end

      exec_exist! 'kubectl', kubectl_install_doc
    end

    unless @options.remote
      appctl_install_doc = if exec_exist? 'gcloud'
        ["run:\n", "  ", Paint["gcloud components install pkg", :bold]]
      else
        gcloud_install_doc
      end
      exec_exist! 'appctl', appctl_install_doc

      unless `git status --porcelain`.strip.empty?
        log :failure, "git worktree is dirty."
        fatal Paint["appctl(1)", :bold] + " insists on a clean worktree. Please commit or discard your changes."
      end
      log :success, "git worktree is clean"
    end

    @environment_validated = true
  end

  def execute(input: $stdin, output: $stdout)
    self.validate_environment

    if @options.remote
      log :step, "trigger Github Actions workflow 'appctl-apply' on deployment repo"

      require_relative 'trigger'

      trigger_cmd = Orbital::Commands::Trigger.new({
        "repo" => "deployment",
        "workflow" => "appctl-apply"
      })

      trigger_cmd.add_inputs({
        target_env: @options.env,
        release_name: @options.tag
      })

      fatal "workflow failed!" unless trigger_cmd.execute
    else
      deployment_repo_default_branch = "#{self.app_name}-environment"

      if @deployment_worktree_root.directory?
        log :step, "fast-forward appctl deployment repo"

        Dir.chdir(@deployment_worktree_root.to_s) do
          run 'git', 'fetch', 'upstream', '--tags', '--prune', '--prune-tags'

          upstream_branches = `git for-each-ref refs/heads --format="%(refname:short)"`.chomp.split("\n").sort

          # move default branch to the end, so it ends up staying checked out
          upstream_branches -= [deployment_repo_default_branch]
          upstream_branches += [deployment_repo_default_branch]

          upstream_branches.each do |branch|
            run 'git', 'checkout', '--quiet', branch
            run 'git', 'reset', '--hard', "upstream/#{branch}"
          end
        end
      else
        log :step, "clone appctl deployment repo"

        deployment_repo_uri = URI(@appctl_config['deployment_repo_url'])

        clone_uri_str = "git@#{deployment_repo_uri.hostname}:#{deployment_repo_uri.path[1..-1]}.git"

        run 'git', 'clone', clone_uri_str, @deployment_worktree_root.to_s

        Dir.chdir(@deployment_worktree_root.to_s) do
          run 'git', 'remote', 'rename', 'origin', 'upstream'
        end
      end

      log :step, ["prepare k8s ", Paint[@options.env, :bold], " release ", Paint[@options.tag, :bold]]
      run "appctl", "prepare", @options.env, "--from-tag", @options.tag, "--validate"
      Dir.chdir(@deployment_worktree_root.to_s) do
        run 'git', 'checkout', deployment_repo_default_branch
      end

      log :step, ["deploy k8s ", Paint[@options.env, :bold], " release ", Paint[@options.tag, :bold]]
      run "appctl", "apply", @options.env, "--from-tag", @options.tag
    end

    unless @options.wait
      log :break
      log :celebrate, [
        Paint[self.app_name, :bold],
        " release ",
        Paint[@options.tag, :bold],
        " deployed.\n\nPlease ",
        link_to(
          self.gke_app_dashboard_uri,
          "visit the Google Cloud dashboard for this Kubernetes Application"
        ),
        " to ensure resources have converged."
      ]

      return
    end

    log :step, "wait for k8s to converge"
    if self.wait_for_k8s_to_converge
      log :break
      log :celebrate, [
        Paint[self.app_name, :bold],
        " release ",
        Paint[@options.tag, :bold],
        " deployed."
      ]
    else
      log :break
      log :info, [
        "Kubernetes resources for ",
        Paint[self.app_name, :bold],
        " release ",
        Paint[@options.tag, :bold],
        " have been loaded into the cluster; but the cluster state did not converge. Please ",
        link_to(
          self.gke_app_dashboard_uri,
          "visit the Google Cloud dashboard for this Kubernetes Application"
        ),
        " to determine its status."
      ]
    end
  end

  def gke_app_dashboard_uri
    appctl_active_env = self.target_environments[@options.env]

    URI("https://console.cloud.google.com/kubernetes/application/#{appctl_active_env['compute']['zone']}/#{appctl_active_env['cluster_name']}/#{appctl_active_env['namespace']}/#{self.app_name}?project=#{appctl_active_env['project']}")
  end

  class ConvergePoller < Orbital::Spinner::PollingSpinner
    attr_accessor :k8s_namespace
    attr_accessor :k8s_app_name
    attr_accessor :tag_to_match

    def status_command
      [
        'kubectl', 'get',
        'releasetracks.app.gke.io',
        @k8s_app_name,
        '--namespace', @k8s_namespace,
        '--output', 'jsonpath={.status.conditions[0]}'
      ]
    end

    def poll
      JSON.parse(IO.popen(self.status_command){ |io| io.read }.strip)
    end

    def state
      if @result and @result["type"] == "Completed" && @result["status"] == "True" && @result["message"].match?(@tag_to_match)
        :success
      elsif Time.now - @started_at >= 120.0
        :failure
      elsif @poll_attempts > 0
        :in_progress
      else
        :queued
      end
    end

    def resolved?
      not([:in_progress, :queued].include?(self.state))
    end
  end

  def wait_for_k8s_to_converge
    appctl_active_env = self.target_environments[@options.env]

    wait_text = [
        "Waiting for application resource '",
        Paint[self.app_name, :bold],
        "' in env '",
        Paint[@options.env, :bold],
        "' to match release ",
        Paint[@options.tag, :bold]
    ]

    poller = ConvergePoller.new(wait_text: wait_text)
    poller.tag_to_match = @options.tag
    poller.k8s_app_name = self.app_name
    poller.k8s_namespace = appctl_active_env['namespace']

    poller.run

    if poller.state == :failure
      log :warning, "No activity after 120s; giving up!"
    end

    poller.state == :success
  end
end
