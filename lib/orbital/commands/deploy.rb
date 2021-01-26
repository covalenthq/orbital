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
require 'orbital/ext/core/uri_join'
require 'orbital/ext/core/to_flat_string'

require 'k8s-ruby'
require 'orbital/ext/k8s-ruby/resource_client_helpers'
require 'paint'

require 'orbital/command'
require 'orbital/deployment_repo_helpers'
require 'orbital/spinner/polling_spinner'

module Orbital; end
module Orbital::Commands; end
class Orbital::Commands::Deploy < Orbital::Command
  def initialize(*opts)
    super(*opts)
    @options.deployer = @options.deployer.intern
    if app = @context.application
      app.select_deploy_environment(@options.env)
    end
  end

  include Orbital::DeploymentRepoHelpers

  def validate_environment!
    return if @context_validated

    logger.step "ensure shell environment is sane for deploy"

    gcloud_install_doc = [link_to(
      "https://cloud.google.com/sdk/docs/install",
      "install the Google Cloud SDK."
    ), '.']

    if @options.deployer == :appctl
      appctl_install_doc = if exec_exist? 'gcloud'
        ["run:\n", "  ", Paint["gcloud components install pkg", :bold]]
      else
        gcloud_install_doc
      end
      @context.validate :cmd_appctl do
        exec_exist! 'appctl', appctl_install_doc
      end
    end

    @context.validate :has_project do
      @context.project!
      logger.success "project is available"
    end

    if @options.deployer == :appctl
      @context.validate :project_worktree_clean do
        if @context.project.worktree_clean?
          logger.success "project worktree is clean"
        else
          logger.failure "project worktree is dirty."
          logger.fatal Paint["appctl(1)", :bold] + " insists on a clean worktree. Please commit or discard your changes."
        end
      end
    end

    @context.validate :has_appctlconfig do
      @context.application!
      logger.success ["project is configured for appctl (", Paint[".appctlconfig", :bold], " is available)"]
    end

    if @options.wait
      @context.validate :has_kubeconfig do
        if @context.shell.kubectl_config_path.file?
          logger.success ["shell is configured with a kubectl cluster (", Paint["~/.kube/config", :bold], " is available)"]
        elsif exec_exist? 'gcloud'
          logger.success [Paint["~/.kube/config", :bold], " can be configured by ", Paint["gcloud(1)", :bold]]
        else
          logger.fatal [
            Paint["~/.kube/config", :bold], " is not configured, and ",
            Paint["gcloud(1)", :bold], "is not available to generate it. Please ",
            gcloud_install_doc
          ]
        end
      end
    end

    @context_validated = true
  end

  def execute
    self.validate_environment!

    begin
      do_execute
    ensure
      execute_deferred_cleanups
    end
  end

  private

  def do_execute
    self.ensure_up_to_date_deployment_repo

    active_env = @context.application.active_deploy_environment
    k8s_releasetrack_prev_transition_time = Time.at(0)
    deploy_start_time = Time.now

    if @options.wait
      self.ensure_k8s_client_configured_for_active_env!

      logger.step "examine existing k8s resources"

      if reltrack = active_env.k8s_resources.releasetracks.maybe_get(active_env.k8s_app_resource_name)
        last_transition_dt_str =
          reltrack.status.conditions.last.lastTransitionTime

        k8s_releasetrack_prev_transition_time =
          DateTime.parse(last_transition_dt_str).to_time

        logger.success [
          "last released to env '", Paint[@options.env, :bold], "'",
          " on ", Paint[k8s_releasetrack_prev_transition_time.localtime.strftime("%Y-%m-%d"), :bold],
          " at ", Paint[k8s_releasetrack_prev_transition_time.localtime.strftime("%I:%M:%S %p %Z"), :bold]
        ]
      else
        logger.info ["no existing resources found for env '", Paint[@options.env, :bold], "'"]
      end
    end

    case @options.deployer
    when :internal
      self.ensure_k8s_client_configured_for_active_env!

      ar_release_tag_ref = run(
        'git', 'rev-parse', "refs/tags/#{@options.tag}",
        capturing_output: true
      ).strip

      dr_env_tag_base_name = "#{@options.tag}-#{@options.env}-#{ar_release_tag_ref[0, 7]}"

      dr_env_tag_refs = run(
        'git', 'tag', '--list',
        chdir: @context.application.deployment_worktree.to_s,
        capturing_output: true
      )

      dr_env_tag =
        dr_env_tag_refs.chomp.split("\n")
        .filter{ |ln| ln.start_with?(dr_env_tag_base_name) }
        .sort_by{ |ln| ln.split('.').last.to_i }
        .last

      dr_env_tag_ref = run(
        'git', 'rev-parse', "refs/tags/#{dr_env_tag}",
        chdir: @context.application.deployment_worktree.to_s,
        capturing_output: true
      ).strip

      logger.step ["deploy k8s ", Paint[@options.env, :bold], " release ", Paint[@options.tag, :bold], ' (', dr_env_tag, ')']

      if active_env.k8s_resources.crds.member?('releasetracks.app.gke.io')
        logger.skipped ["target cluster '", Paint[active_env.gke_cluster_name, :bold], "' has KALM installed"]
      else
        # TODO: install KALM
        logger.fatal ["KALM not installed into the target k8s cluster!"]
      end

      if active_env.k8s_resources.ensure_app_namespace!
        logger.success ["create k8s namespace '", Paint[active_env.k8s_namespace, :bold], "'"]
      else
        logger.skipped ["k8s namespace '", Paint[active_env.k8s_namespace, :bold], "' exists"]
      end

      reltrack_res_name = [active_env.k8s_namespace, active_env.k8s_app_resource_name].join('/')

      if old_reltrack_res = active_env.k8s_resources.releasetracks.maybe_get(active_env.k8s_app_resource_name)
        logger.skipped ["k8s releasetrack '", Paint[reltrack_res_name, :bold], "' exists"]
      else
        # TODO (appctl-apply phase):
        # - create deployer ServiceAccount in namespace, and ClusterRoleBinding to deployer ClusterRole
        # - create git-token secret in namespace (github token w/ read permission on deployment repo)
        # - create/update releasetrack for "#{active_env.namespace}/#{app_name}"
        logger.fatal ["support for initial environment stand-up has not been implemented"]
      end

      reltrack_patch_doc = {
        metadata: {
          annotations: {
            'appctl.gke.io/config-commit-link' => @context.application.app_repo.uri.join("/commit/#{ar_release_tag_ref}"),
            'appctl.gke.io/deployment-commit-link' => @context.application.deployment_repo.uri.join("/commit/#{dr_env_tag_ref}"),
            'appctl.gke.io/deployment-tag-link' => @context.application.deployment_repo.uri.join("/tree/#{dr_env_tag}")
          }
        },
        spec: {
          version: dr_env_tag,
        }
      }

      active_env.k8s_resources.releasetracks.merge_patch(
        active_env.k8s_app_resource_name,
        reltrack_patch_doc,
        strategic_merge: false
      )

      logger.success ["retarget k8s releasetrack resource '", Paint[reltrack_res_name, :bold], "' to deployment-repo tag '", Paint[dr_env_tag, :bold], "'"]

      # reltrack_res = active_env.k8s_resources.releasetracks.maybe_get(active_env.k8s_app_resource_name)
      # else
      #   reltrack_rc = K8s::Resource.new(
      #     apiVersion: 'app.gke.io/v1beta1',
      #     kind: 'ReleaseTrack',
      #     metadata: {
      #       name: active_env.k8s_app_resource_name,
      #       namespace: active_env.k8s_namespace,
      #       annotations: {
      #         'appctl.gke.io/config-repo' => @context.application.app_repo.uri,
      #         'appctl.gke.io/deployment-repo' => @context.application.deployment_repo.uri,
      #         'appctl.gke.io/config-commit-link' => @context.application.app_repo.uri.join("/commit/#{ar_release_tag_ref}"),
      #         'appctl.gke.io/deployment-all-tags' => @context.application.deployment_repo.uri.join("/tags"),
      #         'appctl.gke.io/deployment-commit-link' => @context.application.deployment_repo.uri.join("/commit/#{dr_env_tag_ref}"),
      #         'appctl.gke.io/deployment-tag-link' => @context.application.deployment_repo.uri.join("/tree/#{dr_env_tag}")
      #       }
      #     },
      #     spec: {
      #       sourceRepository: {
      #         type: 'Git',
      #         url: @context.application.deployment_repo.uri.join("?branch=#{active_env.name}"),
      #         secretRef: {
      #           name: 'git-token'
      #         }
      #       },
      #       name: active_env.k8s_app_resource_name,
      #       version: dr_env_tag,
      #       applicationRef: {
      #         name: active_env.k8s_app_resource_name,
      #       },
      #       serviceAccountName: 'deployer'
      #     }
      #   )
      # end

    when :appctl
      logger.step ["deploy k8s ", Paint[@options.env, :bold], " release ", Paint[@options.tag, :bold]]
      run "appctl", "apply", @options.env, "--from-tag", @options.tag

    when :github
      logger.step "trigger Github Actions workflow 'appctl-apply' on deployment repo"

      require 'orbital/commands/trigger'

      trigger_cmd = sibling_command(Orbital::Commands::Trigger,
        repo: "deployment",
        workflow: "appctl-apply"
      )

      trigger_cmd.add_inputs({
        target_env: active_env.name,
        release_name: @options.tag,
        gcp_project_name: active_env.gcp_project,
        gcp_compute_zone: active_env.gcp_compute_zone,
        gke_cluster_name: active_env.gke_cluster_name
      })

      logger.fatal "workflow failed!" unless trigger_cmd.execute
    end

    unless @options.wait
      logger.break(2)
      logger.celebrate [
        Paint[@context.application.name, :bold],
        " release ",
        Paint[@options.tag, :bold],
        " deployed to env '",
        Paint[@options.env, :bold],
        "'.",
        if dash_uri = active_env.dashboard_uri
          [
            "\n\nPlease ",
            link_to(
              dash_uri,
              "visit the dashboard page for this application"
            ),
            " to ensure resources have converged."
          ]
        else
          []
        end
      ]

      return
    end

    self.ensure_k8s_client_configured_for_active_env!

    logger.step "wait for k8s to converge", flush: true

    wait_text = [
        "Waiting for application resource '",
        Paint[@context.application.name, :bold],
        "' in env '",
        Paint[@options.env, :bold],
        "' to match release ",
        Paint[@options.tag, :bold]
    ]

    poller = K8sConvergePoller.new(wait_text: wait_text)
    poller.prev_transition_time = k8s_releasetrack_prev_transition_time
    poller.k8s_client = active_env.k8s_client
    poller.tag_to_match = @options.tag
    poller.k8s_app_name = active_env.k8s_app_resource_name
    poller.k8s_namespace = active_env.k8s_namespace

    poller.run

    case poller.state
    when :success
      logger.break(2)
      logger.celebrate [
        Paint[@context.application.name, :bold],
        " release ",
        Paint[@options.tag, :bold],
        " deployed."
      ]
    when :timeout
      logger.warning "No activity after 120s; giving up!"

      logger.break(2)
      logger.info [
        "Kubernetes resources for ",
        Paint[@context.application.name, :bold],
        " release ",
        Paint[@options.tag, :bold],
        " have been loaded into the '",
        Paint[@options.env, :bold],
        "' environment; but the cluster state did not converge."
      ]
    when :failure
      logger.info "Last poll result:"
      logger.break(1)
      pp poller.result.to_h
      logger.break(2)
      logger.error "Deploy failed!"
    end

    if dash_uri = active_env.dashboard_uri
      logger.break(2)
      logger.info [
        "You can ",
        link_to(
          dash_uri,
          "visit the dashboard page for this application"
        ),
        " to view detailed status information."
      ]
    end
  end

  def ensure_k8s_client_configured_for_active_env!
    return if @k8s_client_configured_for_active_env

    @context.application.k8s_config_file_populator = lambda do |env|
      logger.step ["get k8s cluster credentials for env '", env.name, "'"]

      run "gcloud", "container", "clusters", "get-credentials", env.gke_cluster_name,
        "--project=#{env.gcp_project}",
        "--zone=#{env.gcp_compute_zone}"
    end

    active_env = @context.application.active_deploy_environment
    active_env.k8s_client

    @k8s_client_configured_for_active_env = true
  end
end

class Orbital::Commands::Deploy::K8sConvergePoller < Orbital::Spinner::PollingSpinner
  attr_accessor :k8s_client
  attr_accessor :k8s_namespace
  attr_accessor :k8s_app_name
  attr_accessor :tag_to_match
  attr_accessor :prev_transition_time

  def poll
    @k8s_client.api('app.gke.io/v1beta1')
    .resource('releasetracks', namespace: @k8s_namespace)
    .maybe_get(@k8s_app_name)
    &.status
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
