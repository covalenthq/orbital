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
  def initialize(*opts)
    super(*opts)
    @environment.project.appctl.select_deploy_environment(@options.env)
  end

  def validate_environment!
    return if @environment_validated

    log :step, "ensure shell environment is sane for deploy"

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

      @environment.validate :cmd_kubectl do
        exec_exist! 'kubectl', kubectl_install_doc
      end
    end

    unless @options.remote
      appctl_install_doc = if exec_exist? 'gcloud'
        ["run:\n", "  ", Paint["gcloud components install pkg", :bold]]
      else
        gcloud_install_doc
      end
      @environment.validate :cmd_appctl do
        exec_exist! 'appctl', appctl_install_doc
      end

      @environment.validate :git_worktree_clean do
        unless `git status --porcelain`.strip.empty?
          log :failure, "git worktree is dirty."
          fatal Paint["appctl(1)", :bold] + " insists on a clean worktree. Please commit or discard your changes."
        end
        log :success, "git worktree is clean"
      end
    end

    @environment.validate :has_project do
      @environment.project!
      log :success, "project is available"
    end

    @environment.validate :has_appctlconfig do
      @environment.project.appctl!
      log :success, "project is configured for appctl"
    end

    @environment_validated = true
  end

  def execute(input: $stdin, output: $stdout)
    self.validate_environment!

    if @options.remote
      unless @environment.project.appctl.deployment_worktree
        self.clone_deployment_repo
      end

      log :step, "trigger Github Actions workflow 'appctl-apply' on deployment repo"

      require_relative 'trigger'

      trigger_cmd = sibling_command(Orbital::Commands::Trigger,
        repo: "deployment",
        workflow: "appctl-apply"
      )

      active_env = @environment.project.appctl.active_deploy_environment

      trigger_cmd.add_inputs({
        target_env: active_env.name,
        release_name: @options.tag,
        gcp_project_name: active_env.project,
        gcp_compute_zone: active_env.compute.zone,
        gke_cluster_name: active_env.cluster_name
      })

      fatal "workflow failed!" unless trigger_cmd.execute
    else
      if @environment.project.appctl.deployment_worktree
        log :step, "fast-forward appctl deployment repo"

        Dir.chdir(@environment.project.appctl.deployment_worktree_root.to_s) do
          run 'git', 'fetch', 'upstream', '--tags', '--prune', '--prune-tags'

          upstream_branches = `git for-each-ref refs/heads --format="%(refname:short)"`.chomp.split("\n").sort

          # move default branch to the end, so it ends up staying checked out
          upstream_branches -= [@environment.project.appctl.deployment_repo.default_branch]
          upstream_branches += [@environment.project.appctl.deployment_repo.default_branch]

          upstream_branches.each do |branch|
            run 'git', 'checkout', '--quiet', branch
            run 'git', 'reset', '--hard', "upstream/#{branch}"
          end
        end
      else
        self.clone_deployment_repo
      end

      log :step, ["prepare k8s ", Paint[@options.env, :bold], " release ", Paint[@options.tag, :bold]]
      run "appctl", "prepare", @options.env, "--from-tag", @options.tag, "--validate"
      Dir.chdir(@environment.project.appctl.deployment_worktree_root.to_s) do
        run 'git', 'checkout', @environment.project.appctl.deployment_repo.default_branch
      end

      log :step, ["deploy k8s ", Paint[@options.env, :bold], " release ", Paint[@options.tag, :bold]]
      run "appctl", "apply", @options.env, "--from-tag", @options.tag
    end

    unless @options.wait
      log :break
      log :celebrate, [
        Paint[@environment.project.appctl.application_name, :bold],
        " release ",
        Paint[@options.tag, :bold],
        " deployed.\n\nPlease ",
        link_to(
          @environment.project.appctl.gke_app_dashboard_uri,
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
        Paint[@environment.project.appctl.application_name, :bold],
        " release ",
        Paint[@options.tag, :bold],
        " deployed."
      ]
    else
      log :break
      log :info, [
        "Kubernetes resources for ",
        Paint[@environment.project.appctl.application_name, :bold],
        " release ",
        Paint[@options.tag, :bold],
        " have been loaded into the cluster; but the cluster state did not converge. Please ",
        link_to(
          @environment.project.appctl.gke_app_dashboard_uri,
          "visit the Google Cloud dashboard for this Kubernetes Application"
        ),
        " to determine its status."
      ]
    end
  end

  def clone_deployment_repo
    log :step, "clone appctl deployment repo"

    run 'git', 'clone', @environment.project.appctl.deployment_repo.clone_uri, @environment.project.appctl.deployment_worktree_root.to_s

    Dir.chdir(@environment.project.appctl.deployment_worktree_root.to_s) do
      run 'git', 'remote', 'rename', 'origin', 'upstream'
    end
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
    wait_text = [
        "Waiting for application resource '",
        Paint[@environment.project.appctl.application_name, :bold],
        "' in env '",
        Paint[@options.env, :bold],
        "' to match release ",
        Paint[@options.tag, :bold]
    ]

    poller = ConvergePoller.new(wait_text: wait_text)
    poller.tag_to_match = @options.tag
    poller.k8s_app_name = @environment.project.appctl.application_name
    poller.k8s_namespace = @environment.project.appctl.active_deploy_environment.namespace

    poller.run

    if poller.state == :failure
      log :warning, "No activity after 120s; giving up!"
    end

    poller.state == :success
  end
end
