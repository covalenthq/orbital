# frozen_string_literal: true

require 'ostruct'
require 'yaml'

require 'kustomize'

require 'orbital/command'
require 'orbital/deployment_repo_helpers'
require 'orbital/ext/core/pathname_modify_as_yaml'

module Orbital; end
module Orbital::Commands; end
class Orbital::Commands::Release < Orbital::Command
  def initialize(*args)
    super(*args)
    if @options.imagebuilder
      @options.imagebuilder = @options.imagebuilder.intern
    end

    if @options.deploy
      @options.prepare = true
    end

    if @options.prepare.nil?
      @options.prepare = !!(@context.application&.deployment_repo)
    end
  end

  include Orbital::DeploymentRepoHelpers

  def validate_environment!
    return if @context_validated
    logger.step "ensure shell environment is sane for release"

    case @options.imagebuilder
    when :github, :cloudbuild
      @context.validate :cmd_gcloud do
        exec_exist! 'gcloud', [link_to(
          "https://cloud.google.com/sdk/docs/install",
          "install the Google Cloud SDK."
        ), '.']
      end
    when :docker
      @context.validate :cmd_docker do
        exec_exist! 'docker', [link_to(
          "https://docs.docker.com/get-docker/",
          "install Docker"
        ), '.']
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
        logger.fatal "Releases can only be built against a clean worktree. Please commit or discard your changes."
      end
    end

    @context.validate :has_appctlconfig do
      @context.application!
      logger.success ["project is configured for appctl (", Paint[".appctlconfig", :bold], " is available)"]
    end

    @context_validated = true
  end

  def execute(input: $stdin, output: $stdout)
    self.validate_environment!

    deploy_cmd = nil

    if @options.deploy
      require 'orbital/commands/deploy'

      deploy_cmd_opts = @options.dup.to_h.merge({
        tag: "dummy"
      })

      deploy_cmd = sibling_command(Orbital::Commands::Deploy, **deploy_cmd_opts)

      deploy_cmd.validate_environment!
    end

    logger.step "collect release information"

    @release = OpenStruct.new
    @release.created_at = Time.now

    @context.project.proposed_release = @release

    @release.from_git_branch = `git branch --show-current`.strip
    @release.from_git_branch = nil if @release.from_git_branch.empty?
    @release.from_git_ref = `git rev-parse HEAD`.strip
    logger.success "determine git worktree state"

    run 'git', 'fetch'

    existing_git_tags = run(
      'git', 'describe', '--tags', '--exact-match', 'HEAD',
      capturing_output: true,
      fail_ok: true,
      err: '/dev/null'
    ).split("\n").map{ |ln| ln.strip }.to_set

    # if existing_release_name = existing_git_tags.find{ |t| t =~ /^v\d+/ }
    #   logger.fatal ["This commit has already been released as ", Paint[existing_release_name, :bold]]
    # else
    #   logger.success "git commit not yet tagged as a release"
    # end

    if @release.from_git_branch
      origin_git_branch = "origin/#{@release.from_git_branch}"

      origin_git_ref = run(
        'git', 'rev-parse', origin_git_branch,
        capturing_output: true,
        fail_ok: true,
        err: '/dev/null'
      ).strip
      origin_git_ref = nil if origin_git_ref !~ /[0-9a-f]{40}/i

      if origin_git_ref
        if origin_git_ref == @release.from_git_ref
          logger.success ["local git ref for '", @release.from_git_branch, "' matches ref for '", origin_git_branch, "'"]
        else
          logger.failure ["local git ref for '", @release.from_git_branch, "' ", Paint["does not match", :bold], " ref for '", origin_git_branch, "'"]
          logger.fatal "Cowardly refusing to create a potentially non-reproducible build.\n\nPlease ensure the current git branch is synced with the remote before releasing."
        end
      else
        logger.info ["local git ref '", @release.from_git_branch, "' ", Paint["does not exist", :bold], " on the remote"]
      end
    else
      logger.skipped "git remote not checked for sync (not on a branch)"
    end

    @release.artifacts = {}

    @release.tag = OpenStruct.new(
      name: "v#{Time.now.strftime("%Y%m%d%H%M%S")}",
      state: :not_pushed
    )
    logger.step "create a release tag based on the current datetime (like GAE)"

    with_temporary_git_tag(@release.tag) do
      @context.project.artifact_blueprints.each do |artifact_name, build_steps|
        artifact_final_details = build_steps.each.with_index.inject({}) do |acc, (build_step, i)|
          logger.step ["build ", Paint[artifact_name, :blue], " (phase ", Paint[(i + 1).to_s, :bold], "): ", build_step[:name]]

          step_details = case build_step[:builder]
          in :docker_image
            image_name = build_step.dig(:params, :image_name)
            logger.fatal "image_name is required in docker_image builds" unless image_name

            source_path = build_step.dig(:params, :source_path) || @context.project.root
            docker_spec_type = build_step.dig(:params, :spec_type) || 'Dockerfile'
            logger.success "collect build-step configuration"

            build_docker_image(docker_spec_type, source_path: source_path, image_name: image_name)
          end

          acc.merge((step_details || {}).filter{ |k, v| v }.to_h)
        end

        @release.artifacts[artifact_name] = artifact_final_details
      end

      logger.debug("@release.artifacts: " + @release.artifacts.inspect)

      if @release.tag.state == :not_pushed
        logger.step "push tag (and accompanying git objects)"
        run "git", "push", "origin", @release.tag.name
        @release.tag.state = :pushed
      end

      if @options.prepare
        with_deployment_repo do
          publish_to_deployment_repo!
        end
      end
    end

    if deploy_cmd
      deploy_cmd.options.tag = @release.tag.name
      deploy_cmd.execute
    end
  end

  private
  def publish_to_deployment_repo!
    publish_start_time = Time.now

    logger.step "examine deployment repo state"
    dr_log_branch = @context.application.deployment_repo.default_branch

    ar_release_tag_ref = run(
      'git', 'rev-parse', "refs/tags/#{@release.tag.name}",
      capturing_output: true
    ).strip

    dr_env_tag_refs = run(
      'git', 'tag', '--list',
      chdir: @context.application.deployment_worktree.to_s,
      capturing_output: true
    )

    dr_push_refs = []
    dr_push_and_track_refs = []

    @context.application.deploy_environments.each do |_, deploy_env|
      dr_env_branch = deploy_env.name.to_s

      logger.step ["publish k8s resource-config for env '", Paint[deploy_env.name.to_s, :bold], "'"]

      unless deploy_env.kustomization_dir.directory?
        logger.fatal ["kustomization directory for env '", Paint[deploy_env.name.to_s, :bold], "' does not exist"]
      end

      kustomize_emitter = Kustomize.load(deploy_env.kustomization_dir, session: @context.kustomize_session)

      hydrated_config = kustomize_emitter.to_yaml_stream

      logger.success ["built ", Paint["artifact.yaml", :bold], " (", hydrated_config.length.to_s, " bytes)"]

      dr_checked_out_branch = run(
        'git', 'rev-parse', '--abbrev-ref', 'HEAD',
        chdir: @context.application.deployment_worktree.to_s,
        capturing_output: true
      ).strip

      run(
        'git', 'show-ref', '--verify', '--quiet', "refs/remotes/upstream/#{dr_env_branch}",
        chdir: @context.application.deployment_worktree.to_s,
        capturing_output: true,
        fail_ok: true
      )
      dr_branch_upstream_exists = $?.success?

      if dr_branch_upstream_exists
        run(
          'git', 'checkout', '--quiet', '-B', dr_env_branch, "upstream/#{dr_env_branch}",
          chdir: @context.application.deployment_worktree.to_s
        )
        dr_push_refs << "refs/heads/#{dr_env_branch}"
      else
        run(
          'git', 'checkout', '--quiet', '--orphan', dr_env_branch,
          chdir: @context.application.deployment_worktree.to_s
        )
        dr_push_and_track_refs << "refs/heads/#{dr_env_branch}"
      end

      artifact_path = @context.application.deployment_worktree / 'artifact.yaml'

      unless artifact_path.file? and artifact_path.read == hydrated_config
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

      dr_env_tag_base_name = "#{@release.tag.name}-#{deploy_env.name}-#{ar_release_tag_ref[0, 7]}"

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
        chdir: @context.application.deployment_worktree.to_s
      )

      dr_push_refs << "refs/tags/#{dr_env_tag}"
    end

    logger.step "update deployment log"

    run(
      'git', 'checkout', '--quiet', dr_log_branch,
      chdir: @context.application.deployment_worktree.to_s
    )

    run(
      'git', 'reset', '--hard', "upstream/#{dr_log_branch}",
      chdir: @context.application.deployment_worktree.to_s
    )

    envs_path = @context.application.deployment_worktree / 'environments.yaml'

    unless envs_path.file?
      envs_docs = @context.application.env_paths.sort.map do |f|
        doc = YAML.load(f.read)
        doc['creation_time'] = publish_start_time.utc.strftime("%Y-%m-%dT%H:%M:%SZ")
        doc
      end

      envs_path.open('w'){ |f| f.write({'envs' => envs_docs}.to_yaml) }
    end

    envs_path.modify_as_yaml do |docs|
      docs[0]['envs'].each do |env_doc|
        env_doc['last_update_time'] = publish_start_time.utc.strftime("%Y-%m-%dT%H:%M:%SZ")
      end

      docs
    end

    run(
      'git', 'add', envs_path.to_s,
      chdir: @context.application.deployment_worktree.to_s
    )

    env_names = @context.application.deploy_environments.keys.map(&:to_s).join(', ')
    run(
      'git', 'commit', '-m', "orbital: update environment data for #{env_names}",
      chdir: @context.application.deployment_worktree.to_s
    )

    dr_push_refs << "refs/heads/#{dr_log_branch}"


    logger.step "push deployment-repo commits and tags to upstream"

    dr_push_and_track_refs.each do |ref|
      run(
        'git', 'push', '--set-upstream', 'upstream', ref,
        chdir: @context.application.deployment_worktree.to_s
      )
    end

    run(
      'git', 'push', 'upstream', *dr_push_refs,
      chdir: @context.application.deployment_worktree.to_s
    )

    @release.published = true
  end

  DEFAULT_IMAGEBUILDER_BACKENDS = {
    'Dockerfile' => :docker,
    'jib' => :gradle
  }

  private
  def build_docker_image(engine, image_name:, source_path:)
    docker_image = OpenStruct.new({
      image_name: image_name,
      image_ref: "#{image_name}:#{@release.tag.name}",
      source_path: source_path
    })

    registry_part, path_part =
      if image_name.split('/').length > 2
         image_name.split('/', 2)
      else
        ['hub.docker.com', image_name]
      end

    docker_image.registry_hostname = registry_part
    docker_image.image_path_in_registry = path_part

    engine_backend =
      @options.imagebuilder || DEFAULT_IMAGEBUILDER_BACKENDS[engine]

    logger.info [
      "building Docker image ",
      Paint[docker_image.image_ref, :bright]
    ]

    logger.info [
      "using build backend ",
      Paint[engine.to_s, :bright],
      Paint["+", :blue],
      Paint[engine_backend.to_s, :bright]
    ]

    image_digest = case [engine, engine_backend]
    in ['Dockerfile', :github]
      build_docker_image_dockerfile_github(docker_image)
    in ['Dockerfile', :cloudbuild]
      build_docker_image_dockerfile_cloudbuild(docker_image)
    in ['Dockerfile', :docker]
      build_docker_image_dockerfile_docker(docker_image)
    in ['jib', :gradle]
      build_docker_image_jib_gradle(docker_image)
    else
      logger.fatal "unsupported engine+backend combination!"
    end

    {
      "type" => "DockerImage",
      "buildEngine" => engine,
      "image.name" => image_name,
      "image.tag" => docker_image.image_ref,
      "image.digest" => image_digest
    }
  end

  def gcloud_access_token
    return @gcloud_access_token if @gcloud_access_token
    @gcloud_access_token = `gcloud auth print-access-token`.strip
    logger.fatal "gcloud authentication error" unless $?.success?
    @gcloud_access_token
  end

  private
  def build_docker_image_dockerfile_github(docker_image)
    if @release.tag.state == :unpushed
      run "git", "push", "origin", @release.tag.name
      @release.tag.state = :tentatively_pushed
      logger.success "tentatively push tag (and accompanying git objects)"
    end

    gcloud_access_token = self.gcloud_access_token

    require 'orbital/commands/trigger'
    trigger_cmd = sibling_command(Orbital::Commands::Trigger,
      repo: "app",
      workflow: "imagebuild",
      branch: @release.tag.name
    )

    trigger_cmd.add_inputs({
      registry_hostname: docker_image.registry_hostname,
      registry_username: 'oauth2accesstoken',
      registry_password: gcloud_access_token,
      image_name: docker_image.image_path_in_registry,
      image_tag: @release.tag.name
    })

    logger.fatal "image build+push failed" unless trigger_cmd.execute

    @release.tag.state = :pushed
    logger.success "image built and pushed"

    nil
  end

  private
  def build_docker_image_dockerfile_cloudbuild(docker_image)
    run "gcloud", "builds", "submit", "--tag", docker_image.image_ref, docker_image.source_path.to_s
    logger.fatal "image build+push failed" unless $?.success?

    logger.success "image built and pushed"

    nil
  end

  private
  def build_docker_image_dockerfile_docker(docker_image)
    run "docker", "build", "-t", docker_image.image_ref, docker_image.source_path.to_s
    logger.fatal "image build failed" unless $?.success?
    logger.success "image built"

    run "docker", "push", docker_image.image_ref
    logger.fatal "image push failed" unless $?.success?
    logger.success "image pushed"

    run(
      'docker', 'inspect', '--format={{index .RepoDigests 0}}', docker_image.image_ref,
      capturing_output: true
    ).strip.split('@')[1]
  end

  private
  def run_gradle(*args, **kwargs)
    gradlew_path = @context.project.root / 'gradlew'

    if gradlew_path.file?
      run(gradlew_path.to_s, *args, **kwargs)
    else
      run('gradle', *args, **kwargs)
    end
  end

  private
  def build_docker_image_jib_gradle(docker_image)
    run_gradle(
      "jib", "--image=#{docker_image.image_ref}",
      chdir: @context.project.root.to_s
    )
    logger.fatal "jib failed" unless $?.success?

    jib_result_doc = JSON.load(@context.project.root / 'build' / 'jib-image.json')

    logger.success "image built and pushed"

    logger.debug "jib_result_doc: #{jib_result_doc.inspect}"
    logger.debug "docker_image: #{docker_image.inspect}"

    if jib_result_doc['image'] == docker_image.image_ref
      jib_result_doc['imageDigest']
    end
  end

  private
  def with_temporary_git_tag(release_tag)
    begin
      run "git", "tag", release_tag.name
      yield
    ensure
      if release_tag.state != :pushed
        self.ensure_cleanup_step_emitted
        if release_tag.state == :tentatively_pushed
          run "git", "push", "--delete", "origin", release_tag.name
          logger.success "delete release tag (remote)"
        end
        run "git", "tag", "--delete", release_tag.name
        logger.success "delete release tag (local)"
      end
    end
  end

  private
  def with_deployment_repo
    begin
      self.ensure_up_to_date_deployment_repo
      yield
    ensure
      unless @release.published
        # stopping in the middle of publication corrupts the deployment repo
        # in a number of complex ways — but it's cheap to just blow it away and
        # let it get cloned again next time
        if dwt = @context.application.deployment_worktree
          self.ensure_cleanup_step_emitted
          dwt.rmtree
          logger.success "purge in-progress publication"
        end
      end
    end
  end

  def ensure_cleanup_step_emitted
    return if @emitted_cleanup_step
    logger.step "clean up"
    @emitted_cleanup_step = true
  end

end
