# frozen_string_literal: true

require 'ostruct'
require 'yaml'

require 'orbital/command'

module Orbital; end
module Orbital::Commands; end
class Orbital::Commands::Release < Orbital::Command
  def initialize(*args)
    super(*args)
    if @options.imagebuilder
      @options.imagebuilder = @options.imagebuilder.intern
    end
  end

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
        env: "staging",
        tag: "dummy"
      })

      deploy_cmd = sibling_command(Orbital::Commands::Deploy, **deploy_cmd_opts)

      deploy_cmd.validate_environment!
    end

    logger.step "collect release information"

    @release = OpenStruct.new

    @context.project.proposed_release = @release

    @release.from_git_branch = `git branch --show-current`.strip
    @release.from_git_branch = nil if @release.from_git_branch.empty?
    @release.from_git_ref = `git rev-parse HEAD`.strip
    logger.success "determine git worktree state"

    @release.tag = OpenStruct.new(
      name: "v#{Time.now.strftime("%Y%m%d%H%M%S")}",
      state: :not_pushed
    )
    logger.step "create a release tag based on the current datetime (like GAE)"

    with_temporary_git_tag(@release.tag) do
      @context.project.build_steps.each.with_index do |build_step, i|
        logger.step "build (phase #{i + 1}): #{build_step[:name]}"

        case build_step[:builder]
        in :docker_image
          image_name = build_step.dig(:params, :image_name)
          logger.fatal "image_name is required in docker_image builds" unless image_name

          source_path = build_step.dig(:params, :source_path) || @context.project.root
          docker_spec_type = build_step.dig(:params, :spec_type) || 'Dockerfile'
          logger.success "collect build-step configuration"

          build_docker_image(docker_spec_type, source_path: source_path, image_name: image_name)
        end
      end

      if @release.tag.state == :not_pushed
        logger.step "push tag (and accompanying git objects)"
        run "git", "push", "origin", @release.tag.name
        @release.tag.state = :pushed
      end
    end

    if deploy_cmd
      deploy_cmd.options.tag = @release.tag.name
      deploy_cmd.execute
    end
  end

  DEFAULT_IMAGEBUILDER_BACKENDS = {
    'Dockerfile' => :docker,
    'jib' => :gradle
  }

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

    case [engine, engine_backend]
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
  end

  def gcloud_access_token
    return @gcloud_access_token if @gcloud_access_token
    @gcloud_access_token = `gcloud auth print-access-token`.strip
    logger.fatal "gcloud authentication error" unless $?.success?
    @gcloud_access_token
  end

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
  end

  def build_docker_image_dockerfile_cloudbuild(docker_image)
    run "gcloud", "builds", "submit", "--tag", docker_image.image_ref, docker_image.source_path.to_s
    logger.fatal "image build+push failed" unless $?.success?

    logger.success "image built and pushed"
  end

  def build_docker_image_dockerfile_docker(docker_image)
    run "docker", "build", "-t", docker_image.image_ref, docker_image.source_path.to_s
    logger.fatal "image build failed" unless $?.success?
    logger.success "image built"

    run "docker", "push", docker_image.image_ref
    logger.fatal "image push failed" unless $?.success?
    logger.success "image pushed"
  end

  def build_docker_image_jib_gradle(docker_image)
    raise NotImplementedError
  end

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

  def ensure_cleanup_step_emitted
    return if @emitted_cleanup_step
    logger.step "clean up"
    @emitted_cleanup_step = true
  end

end
