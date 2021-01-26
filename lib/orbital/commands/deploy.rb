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

    if @options.deployer == :internal
      @context.validate :cmd_kustomize do
        if exec_exist? 'kustomize'
          @kustomizer = lambda do |path|
            run('kustomize', 'build', path.to_s, capturing_output: true)
          end

          logger.success ["have ", Paint["kustomize(1)", :bold]]
        else
          @kustomizer = lambda do |path|
            k = Orbital::Kustomize::KustomizationFile.load(path)
            k.render_stream
          end

          logger.info [
            "using internal pure-Ruby ",
            Paint["kustomize", :bold],
            "; some functionality may not be fully supported."
          ]
        end
      end
    end

    @context.validate :has_project do
      @context.project!
      logger.success "project is available"
    end

    @context.validate :project_worktree_clean do
      if @context.project.worktree_clean?
        logger.success "project worktree is clean"
      else
        logger.failure "project worktree is dirty."
        logger.fatal Paint["appctl(1)", :bold] + " insists on a clean worktree. Please commit or discard your changes."
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
    self.ensure_cloned_deployment_repo

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

      dr_log_branch = @context.application.deployment_repo.default_branch
      dr_env_branch = @options.env

      ar_checked_out_ref = run(
        'git', 'rev-parse', 'HEAD',
        capturing_output: true
      ).strip

      ar_checked_out_ref_symbolic = run(
        'git', 'rev-parse', '--abbrev-ref', 'HEAD',
        capturing_output: true
      ).strip

      ar_release_tag_ref = run(
        'git', 'rev-parse', "refs/tags/#{@options.tag}",
        capturing_output: true
      ).strip

      unless ar_checked_out_ref == ar_release_tag_ref
        ar_return_to_ref =
          if ar_checked_out_ref_symbolic == 'HEAD'
            ar_checked_out_ref
          else
            ar_checked_out_ref_symbolic
          end

        logger.step ["check out release tag '", @options.tag, "'"]
        run('git', 'checkout', '--quiet', ar_release_tag_ref)

        cleanup_for_app_repo_checkout = defer_cleanup do
          run "git", "checkout", "--quiet", ar_return_to_ref
          logger.success "return app worktree to previously-checked-out git ref"
        end
      end

      logger.step ["build k8s resources for env '", Paint[@options.env, :bold], "'"]
      kustomization_target_dir = @context.application.k8s_resources / 'envs' / @options.env
      unless kustomization_target_dir.directory?
        kustomization_target_dir = @context.application.k8s_resources / 'base'
      end
      unless kustomization_target_dir.directory?
        logger.fatal [Paint[kustomization_target_dir.to_s, :bold], " does not exist"]
      end

      hydrated_config = @kustomizer.call(kustomization_target_dir)
      logger.success ["built ", Paint["artifact.yaml", :bold], " (", hydrated_config.length.to_s, " bytes)"]

      unless @context.application.deployment_worktree
        self.clone_deployment_repo
      end

      logger.step "sync deployment repo"
      run(
        'git', 'fetch', 'upstream', '--tags', '--prune', '--prune-tags',
        chdir: @context.application.deployment_worktree_root.to_s
      )

      logger.step "commit built k8s resources to deployment repo"

      dr_checked_out_branch = run(
        'git', 'rev-parse', '--abbrev-ref', 'HEAD',
        chdir: @context.application.deployment_worktree.to_s,
        capturing_output: true
      ).strip

      unless dr_checked_out_branch == dr_env_branch
        run(
          'git', 'checkout', '--quiet', dr_env_branch,
          chdir: @context.application.deployment_worktree.to_s
        )
      end

      cleanup_for_deployment_repo_env_branch_checkout = defer_cleanup do
        run(
          'git', 'checkout', '--quiet', dr_log_branch,
          chdir: @context.application.deployment_worktree.to_s
        )
        logger.success ["return deployment worktree to '", Paint[dr_log_branch, :bold], "' branch"]
      end

      run(
        'git', 'reset', '--hard', "upstream/#{dr_env_branch}",
        chdir: @context.application.deployment_worktree.to_s
      )

      cleanup_for_deployment_worktree_dirty = defer_cleanup do
        run(
          'git', 'clean', '-ffdx',
          chdir: @context.application.deployment_worktree.to_s
        )
        logger.success ["clean deployment worktree"]
      end

      cleanup_for_deployment_env_branch_dangling_commits = defer_cleanup do
        run(
          'git', 'reset', '--hard', "upstream/#{dr_env_branch}",
          chdir: @context.application.deployment_worktree.to_s
        )
        logger.success ["reset deployment checkout to '", Paint["upstream/#{dr_env_branch}", :bold], "'"]
      end

      artifact_path = @context.application.deployment_worktree / 'artifact.yaml'

      unless artifact_path.read == hydrated_config
        artifact_path.open('w'){ |f| f.write(hydrated_config) }

        run(
          'git', 'add', artifact_path.to_s,
          chdir: @context.application.deployment_worktree.to_s
        )

        run(
          'git', 'commit', '-m', 'orbital: generate hydrated kubernetes configuration manifest',
          chdir: @context.application.deployment_worktree.to_s
        )
      end

      dr_env_tag_base_name = "#{@options.tag}-#{@options.env}-#{ar_release_tag_ref[0, 7]}"

      dr_env_tag_refs = run(
        'git', 'tag', '--list',
        chdir: @context.application.deployment_worktree.to_s,
        capturing_output: true
      )

      dr_env_tags_max_suffix_seq =
        dr_env_tag_refs.chomp.split("\n")
        .filter{ |ln| ln.start_with?(dr_env_tag_base_name) }
        .map{ |ln| ln.split('.').last.to_i }
        .max

      dr_env_tag_suffix_seq =
        dr_env_tags_max_suffix_seq ? (dr_env_tags_max_suffix_seq + 1) : 0

      dr_env_tag = "#{dr_env_tag_base_name}.#{dr_env_tag_suffix_seq}"

      cleanup_for_deployment_repo_unpushed_env_tag = defer_cleanup do
        run(
          'git', 'tag', '--delete', dr_env_tag,
          chdir: @context.application.deployment_worktree.to_s
        )
        logger.success ["deleted git tag '", Paint[dr_env_tag, :bold], "'"]
      end

      run(
        'git', 'tag', dr_env_tag,
        chdir: @context.application.deployment_worktree.to_s
      )

      run(
        'git', 'checkout', '--quiet', dr_log_branch,
        chdir: @context.application.deployment_worktree.to_s
      )

      cleanup_for_deployment_env_branch_dangling_commits.cancel
      cleanup_for_deployment_repo_env_branch_checkout.cancel

      run(
        'git', 'reset', '--hard', "upstream/#{dr_log_branch}",
        chdir: @context.application.deployment_worktree.to_s
      )

      cleanup_for_deployment_log_branch_dangling_commits = defer_cleanup do
        run(
          'git', 'reset', '--hard', "upstream/#{dr_log_branch}",
          chdir: @context.application.deployment_worktree.to_s
        )
        logger.success ["reset deployment checkout to '", Paint["upstream/#{dr_log_branch}", :bold], "'"]
      end

      envs_path = @context.application.deployment_worktree / 'environments.yaml'
      envs_path.modify_as_yaml do |docs|
        active_env_part = docs[0]['envs'].find{ |env| env['name'] == @options.env }
        active_env_part['last_update_time'] = deploy_start_time.utc.strftime("%Y-%m-%dT%H:%M:%SZ")
        docs
      end
      run(
        'git', 'add', envs_path.to_s,
        chdir: @context.application.deployment_worktree.to_s
      )

      run(
        'git', 'commit', '-m', "orbital: update environment data for #{@options.env}",
        chdir: @context.application.deployment_worktree.to_s
      )

      logger.step "push deployment-repo commits and tags to upstream"
      run(
        'git', 'push', 'upstream',
        "refs/heads/#{dr_log_branch}",
        "refs/heads/#{@options.env}",
        "refs/tags/#{dr_env_tag}",
        chdir: @context.application.deployment_worktree.to_s
      )

      cleanup_for_deployment_log_branch_dangling_commits.cancel
      cleanup_for_deployment_worktree_dirty.cancel
      cleanup_for_deployment_repo_unpushed_env_tag.cancel

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
      self.ensure_up_to_date_deployment_repo

      logger.step ["prepare k8s ", Paint[@options.env, :bold], " release ", Paint[@options.tag, :bold]]
      run "appctl", "prepare", @options.env, "--from-tag", @options.tag, "--validate"
      run(
        'git', 'checkout', @context.application.deployment_repo.default_branch,
        chdir: @context.application.deployment_worktree_root.to_s
      )

      logger.step ["deploy k8s ", Paint[@options.env, :bold], " release ", Paint[@options.tag, :bold]]
      run "appctl", "apply", @options.env, "--from-tag", @options.tag
    when :github
      unless @context.application.deployment_worktree
        self.clone_deployment_repo
      end

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
