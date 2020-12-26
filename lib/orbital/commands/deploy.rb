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
require 'orbital/kustomize'
require 'orbital/spinner/polling_spinner'
require 'orbital/core_ext/to_flat_string'
require 'orbital/core_ext/pathname_modify_as_yaml'

module Orbital; end
module Orbital::Commands; end
class Orbital::Commands::Deploy < Orbital::Command
  def initialize(*opts)
    super(*opts)
    @options.deployer = @options.deployer.intern
    if @environment.project and @environment.project.appctl
      @environment.project.appctl.select_deploy_environment(@options.env)
    end
  end

  def validate_environment!
    return if @environment_validated

    log :step, "ensure shell environment is sane for deploy"

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
      @environment.validate :cmd_appctl do
        exec_exist! 'appctl', appctl_install_doc
      end
    end

    if @options.deployer == :internal
      @environment.validate :cmd_kustomize do
        if exec_exist? 'kustomize'
          @kustomizer = lambda do |path|
            run('kustomize', 'build', path.to_s, capturing_output: true)
          end

          log :success, ["have ", Paint["kustomize(1)", :bold]]
        elsif exec_exist? 'kubectl'
          @kustomizer = lambda do |path|
            run('kubectl', 'kustomize', 'build', path.to_s, capturing_output: true)
          end

          log :success, ["have ", Paint["kubectl(1)", :bold]]
        elsif
          @kustomizer = lambda do |path|
            k = Orbital::Kustomize::KustomizationFile.load(path)
            k.render_stream
          end

          log :info, [
            "using internal pure-Ruby ",
            Paint["kustomize", :bold],
            "; some functionality may not be fully supported."
          ]
        end
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
    deploy_start_time = Time.now

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

    case @options.deployer
    when :internal
      self.k8s_client

      dr_log_branch = @environment.project.appctl.deployment_repo.default_branch
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

      ar_return_to_ref = nil
      unless ar_checked_out_ref == ar_release_tag_ref
        ar_return_to_ref =
          if ar_checked_out_ref_symbolic == 'HEAD'
            ar_checked_out_ref
          else
            ar_checked_out_ref_symbolic
          end

        log :step, ["check out release tag '", @options.tag, "'"]
        run('git', 'checkout', '--quiet', ar_release_tag_ref)
      end

      log :step, ["build k8s resources for env '", Paint[@options.env, :bold], "'"]
      kustomization_target_dir = @environment.project.appctl.k8s_resources / 'envs' / @options.env
      unless kustomization_target_dir.directory?
        kustomization_target_dir = @environment.project.appctl.k8s_resources / 'base'
      end
      unless kustomization_target_dir.directory?
        fatal [Paint[kustomization_target_dir.to_s, :bold], " does not exist"]
      end

      hydrated_config = @kustomizer.call(kustomization_target_dir)
      log :success, ["built ", Paint["artifact.yaml", :bold], " (", hydrated_config.length.to_s, " bytes)"]

      unless @environment.project.appctl.deployment_worktree
        self.clone_deployment_repo
        return
      end

      log :step, "sync deployment repo"
      run(
        'git', 'fetch', 'upstream', '--tags', '--prune', '--prune-tags',
        chdir: @environment.project.appctl.deployment_worktree_root.to_s
      )

      log :step, "commit built k8s resources to deployment repo"

      dr_checked_out_branch = run(
        'git', 'rev-parse', '--abbrev-ref', 'HEAD',
        chdir: @environment.project.appctl.deployment_worktree.to_s,
        capturing_output: true
      ).strip

      unless dr_checked_out_branch == dr_env_branch
        run(
          'git', 'checkout', '--quiet', dr_env_branch,
          chdir: @environment.project.appctl.deployment_worktree.to_s
        )
      end

      run(
        'git', 'reset', '--hard', "upstream/#{dr_env_branch}",
        chdir: @environment.project.appctl.deployment_worktree.to_s
      )

      artifact_path = @environment.project.appctl.deployment_worktree / 'artifact.yaml'

      unless artifact_path.read == hydrated_config
        artifact_path.open('w'){ |f| f.write(hydrated_config) }
        run(
          'git', 'add', artifact_path.to_s,
          chdir: @environment.project.appctl.deployment_worktree.to_s
        )

        run(
          'git', 'commit', '-m', 'orbital: generate hydrated kubernetes configuration manifest',
          chdir: @environment.project.appctl.deployment_worktree.to_s
        )
      end

      dr_env_tag_base_name = "#{@options.tag}-#{@options.env}-#{ar_release_tag_ref[0, 7]}"

      dr_env_tag_refs = run(
        'git', 'tag', '--list',
        chdir: @environment.project.appctl.deployment_worktree.to_s,
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

      run(
        'git', 'tag', dr_env_tag,
        chdir: @environment.project.appctl.deployment_worktree.to_s
      )

      run(
        'git', 'checkout', '--quiet', dr_log_branch,
        chdir: @environment.project.appctl.deployment_worktree.to_s
      )

      run(
        'git', 'reset', '--hard', "upstream/#{dr_log_branch}",
        chdir: @environment.project.appctl.deployment_worktree.to_s
      )

      envs_path = @environment.project.appctl.deployment_worktree / 'environments.yaml'
      envs_path.modify_as_yaml do |docs|
        active_env = docs[0]['envs'].find{ |env| env['name'] == @options.env }
        active_env['last_update_time'] = deploy_start_time.utc.strftime("%Y-%m-%dT%H:%M:%SZ")
        docs
      end
      run(
        'git', 'add', envs_path.to_s,
        chdir: @environment.project.appctl.deployment_worktree.to_s
      )

      run(
        'git', 'commit', '-m', "orbital: update environment data for #{@options.env}",
        chdir: @environment.project.appctl.deployment_worktree.to_s
      )

      log :step, "push deployment-repo commits and tags to upstream"
      run(
        'git', 'push', 'upstream',
        "refs/heads/#{dr_log_branch}",
        "refs/heads/#{@options.env}",
        "refs/tags/#{dr_env_tag}",
        chdir: @environment.project.appctl.deployment_worktree.to_s
      )

      if ar_return_to_ref
        log :step, ["clean up"]
        run('git', 'checkout', '--quiet', ar_return_to_ref)
      end

      # TODO:
      #   - in app repo:
      #     - generate hydrated config: run kustomize(1) against ".appctl/config/#{@options.env}" dir
      #     - get commit hash of release tag in app repo
      #   - in deployment repo:
      #     - check out + fast-forward "#{@options.env}" branch
      #     - update + git-add README (arbitrary) to ensure at least a trivial change is made
      #     - update + git-add artifact.yaml with hydrated config
      #     - git commit
      #     - git tag as "#{@options.tag}-#{@options.env}-#{app_repo_commit_hash[0..7]}.#{seq}"
      #       where `seq` increments in case of collision with existing tag
      #     - push branch, tag to upstream

      log :step, ["deploy k8s ", Paint[@options.env, :bold], " release ", Paint[@options.tag, :bold]]

      # TODO:
      # - ensure kubectl current-context is pointed to target cluster
      # - detect if k8s CRD releasetracks.app.gke.io is available; if not, abort
      # - create "#{active_env.namespace}" namespace
      # - create deployer ServiceAccount in namespace, and ClusterRoleBinding to deployer ClusterRole
      # - create git-token secret in namespace (github token w/ read permission on deployment repo)
      # - create/update releasetrack for "#{active_env.namespace}/#{app_name}"
      # - if we switched kubectl contexts at the beginning, switch back

      return

    when :appctl
      self.ensure_up_to_date_deployment_repo

      log :step, ["prepare k8s ", Paint[@options.env, :bold], " release ", Paint[@options.tag, :bold]]
      run "appctl", "prepare", @options.env, "--from-tag", @options.tag, "--validate"
      Dir.chdir(@environment.project.appctl.deployment_worktree_root.to_s) do
        run 'git', 'checkout', @environment.project.appctl.deployment_repo.default_branch
      end

      log :step, ["deploy k8s ", Paint[@options.env, :bold], " release ", Paint[@options.tag, :bold]]
      run "appctl", "apply", @options.env, "--from-tag", @options.tag
    when :github
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

  def ensure_up_to_date_deployment_repo
    unless @environment.project.appctl.deployment_worktree
      self.clone_deployment_repo
      return
    end

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
