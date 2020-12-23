# frozen_string_literal: true

require 'pathname'
require 'yaml'
require 'json'
require 'ostruct'
require 'singleton'
require 'uri'
require 'set'
require 'pp'
require 'date'

require 'k8s-ruby'
require 'paint'

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

    unless @options.remote
      appctl_install_doc = if exec_exist? 'gcloud'
        ["run:\n", "  ", Paint["gcloud components install pkg", :bold]]
      else
        gcloud_install_doc
      end
      @environment.validate :cmd_appctl do
        exec_exist! 'appctl', appctl_install_doc
      end
    end

    @environment.validate :has_project do
      @environment.project!
      log :success, "project is available"
    end

    @environment.validate :project_worktree_clean do
      if @environment.project.worktree_clean?
        log :success, "project worktree is clean"
      else
        log :failure, "project worktree is dirty."
        fatal Paint["appctl(1)", :bold] + " insists on a clean worktree. Please commit or discard your changes."
      end
    end

    @environment.validate :has_appctlconfig do
      @environment.project.appctl!
      log :success, ["project is configured for appctl (", Paint[".appctlconfig", :bold], " is available)"]
    end

    if @options.wait
      @environment.validate :has_kubeconfig do
        if @environment.shell.kubectl_config_path.file?
          log :success, ["shell is configured with a kubectl cluster (", Paint["~/.kube/config", :bold], " is available)"]
        elsif exec_exist? 'gcloud'
          log :success, [Paint["~/.kube/config", :bold], " can be configured by ", Paint["gcloud(1)", :bold]]
        else
          fatal [
            Paint["~/.kube/config", :bold], " is not configured, and ",
            Paint["gcloud(1)", :bold], "is not available to generate it. Please ",
            gcloud_install_doc
          ]
        end
      end
    end

    @environment_validated = true
  end

  def execute(input: $stdin, output: $stdout)
    self.validate_environment!

    active_env = @environment.project.appctl.active_deploy_environment
    k8s_releasetrack_prev_transition_time = Time.at(0)

    if @options.wait
      self.k8s_client

      log :step, "examine existing k8s resources"
      begin
        resource =
          self.k8s_client.api('app.gke.io/v1beta1')
          .resource('releasetracks', namespace: @environment.project.appctl.active_deploy_environment.namespace)
          .get(@environment.project.appctl.application_name)

        last_transition_dt_str =
          resource.status.conditions.last.lastTransitionTime

        k8s_releasetrack_prev_transition_time =
          DateTime.parse(last_transition_dt_str).to_time

        log :success, [
          "last released to env '", Paint[@options.env, :bold], "'",
          " on ", Paint[k8s_releasetrack_prev_transition_time.localtime.strftime("%Y-%m-%d"), :bold],
          " at ", Paint[k8s_releasetrack_prev_transition_time.localtime.strftime("%I:%M:%S %p %Z"), :bold]
        ]
      rescue => e
        log :info, "no existing resources found for env '", Paint[@options.env, :bold], "'"
      end
    end

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
        " deployed to env '",
        Paint[@options.env, :bold],
        "'.\n\nPlease ",
        link_to(
          @environment.project.appctl.gke_app_dashboard_uri,
          "visit the Google Kubernetes Engine details page for this application"
        ),
        " to ensure resources have converged."
      ]

      return
    end

    self.k8s_client

    log :step, "wait for k8s to converge"

    wait_text = [
        "Waiting for application resource '",
        Paint[@environment.project.appctl.application_name, :bold],
        "' in env '",
        Paint[@options.env, :bold],
        "' to match release ",
        Paint[@options.tag, :bold]
    ]

    poller = K8sConvergePoller.new(wait_text: wait_text)
    poller.prev_transition_time = k8s_releasetrack_prev_transition_time
    poller.k8s_client = self.k8s_client
    poller.tag_to_match = @options.tag
    poller.k8s_app_name = @environment.project.appctl.application_name
    poller.k8s_namespace = active_env.namespace

    poller.run

    case poller.state
    when :success
      log :break
      log :celebrate, [
        Paint[@environment.project.appctl.application_name, :bold],
        " release ",
        Paint[@options.tag, :bold],
        " deployed."
      ]
    when :timeout
      log :warning, "No activity after 120s; giving up!"

      log :break
      log :info, [
        "Kubernetes resources for ",
        Paint[@environment.project.appctl.application_name, :bold],
        " release ",
        Paint[@options.tag, :bold],
        " have been loaded into the '",
        Paint[@options.env, :bold],
        "' environment; but the cluster state did not converge."
      ]
    when :failure
      log :info, "Last poll result:"
      log :break
      pp poller.result.to_h

      log :error, "Deploy failed!"
    end

    log :break
    log :info, [
      "You can ",
      link_to(
        @environment.project.appctl.gke_app_dashboard_uri,
        "visit the Google Kubernetes Engine details page for this application"
      ),
      " to view detailed status information."
    ]
  end

  def k8s_client
    return @k8s_client if @k8s_client

    unless @environment.shell.kubectl_config_path.file?
      log :step, "get k8s cluster credentials"
      run "gcloud", "container", "clusters", "get-credentials", active_env.cluster_name,
        "--project=#{active_env.project}",
        "--zone=#{active_env.compute.zone}"
    end

    @k8s_client = K8s::Client.config(K8s::Config.load_file(@environment.shell.kubectl_config_path))
  end

  def clone_deployment_repo
    log :step, "clone appctl deployment repo"

    run 'git', 'clone', @environment.project.appctl.deployment_repo.clone_uri, @environment.project.appctl.deployment_worktree_root.to_s

    Dir.chdir(@environment.project.appctl.deployment_worktree_root.to_s) do
      run 'git', 'remote', 'rename', 'origin', 'upstream'
    end
  end
end

class Orbital::Commands::Deploy::K8sConvergePoller < Orbital::Spinner::PollingSpinner
  attr_accessor :k8s_client
  attr_accessor :k8s_namespace
  attr_accessor :k8s_app_name
  attr_accessor :tag_to_match
  attr_accessor :prev_transition_time

  def poll
    begin
      @k8s_client.api('app.gke.io/v1beta1')
      .resource('releasetracks', namespace: @k8s_namespace)
      .get(@k8s_app_name)
      .status
    rescue K8s::Error::NotFound
      nil
    end
  end

  def transition_time(resource_status)
    begin
      last_transition_dt_str = resource_status.conditions.last.lastTransitionTime
      DateTime.parse(last_transition_dt_str).to_time
    rescue => e
      Time.at(0)
    end
  end

  def state
    if @result and transition_time(@result) > @prev_transition_time
      last_cond = @result.conditions.last

      if last_cond.type == "Completed" and last_cond.status == "True" and last_cond.reason == "ApplicationUpdated"
        if @result.currentVersion.start_with?(@tag_to_match)
          # updated to version we expected
          :success
        else
          # updated to some other version (conflicting update?)
          :failure
        end
      elsif last_cond.type == "Completed"
        puts "intermediate transition step info:"
        pp @result.to_h
        :in_progress
      else
        :in_progress
      end
    elsif Time.now - @started_at >= 120.0
      :timeout
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
