# frozen_string_literal: true

require 'ostruct'
require 'yaml'

require 'orbital/command'

module Orbital; end
module Orbital::Commands; end
class Orbital::Commands::Release < Orbital::Command
  def initialize(*args)
    super(*args)
    @options.imagebuilder = @options.imagebuilder.intern
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

    @release.from_git_branch = `git branch --show-current`.strip
    @release.from_git_branch = nil if @release.from_git_branch.empty?
    @release.from_git_ref = `git rev-parse HEAD`.strip
    logger.success "get branch and/or ref to return to"

    @context.project.config

    image_names = @context.project.images.keys

    unless image_names.length == 1
      logger.fatal "multi-image releases not yet implemented"
    end

    @release.docker_image = OpenStruct.new(
      name: image_names.first
    )
    logger.success "get name of Docker image used in k8s deployment config"

    @release.tag = OpenStruct.new(
      name: "v#{Time.now.strftime("%Y%m%d%H%M%S")}",
      state: :not_pushed
    )
    @release.docker_image.ref = "#{@release.docker_image.name}:#{@release.tag.name}"
    logger.success "generate a release name based on the current datetime (like GAE)"

    release_branch_name = "release-#{@release.tag.name}-tmp"
    return_target = @release.from_git_branch || @release.from_git_ref
    on_temporary_branch(release_branch_name, return_target) do
      logger.step "burn release metadata into codebase and k8s resources"
      modified_paths = self.burn_in_release()
      modified_paths.each do |path|
        run "git", "add", path.expand_path.to_s
      end

      logger.step "create a release commit, and tag it"
      logger.spawn "git commit"
      IO.popen(["git", "commit", "--file=-"], "r+") do |io|
        io.puts "Release #{@release.tag.name}\n\n"
        if @release.from_git_branch
          io.puts "Base branch: #{@release.from_git_branch}"
        end
        io.puts "Base commit: #{@release.from_git_ref}"
        io.close_write
        $stderr.write(io.read)
      end

      with_temporary_git_tag(@release.tag) do
        if @options.imagebuilder == :github
          logger.step "push tag (and accompanying git objects)"
          run "git", "push", "origin", @release.tag.name
          @release.tag.state = :tentatively_pushed
        end

        logger.step "build and push Docker image #{@release.docker_image.ref}"

        case @options.imagebuilder
        when :github
          gcloud_access_token = `gcloud auth print-access-token`.strip
          logger.fatal "gcloud authentication error" unless $?.success?

          require_relative 'trigger'

          trigger_cmd = sibling_command(Orbital::Commands::Trigger,
            repo: "app",
            workflow: "imagebuild",
            branch: @release.tag.name
          )

          docker_registry_hostname, docker_image_name_path_part =
            @release.docker_image.name.split('/', 2)

          trigger_cmd.add_inputs({
            registry_hostname: docker_registry_hostname,
            registry_username: 'oauth2accesstoken',
            registry_password: gcloud_access_token,
            image_name: docker_image_name_path_part,
            image_tag: @release.tag.name
          })

          logger.fatal "image build+push failed" unless trigger_cmd.execute
          @release.tag.state = :pushed
          logger.success "image built and pushed"
        when :cloudbuild
          run "gcloud", "builds", "submit", "--tag", @release.docker_image.ref, "."
          logger.fatal "image build+push failed" unless $?.success?
          logger.success "image built and pushed"
        when :docker
          run "docker", "build", "-t", @release.docker_image.ref, "."
          logger.fatal "image build failed" unless $?.success?
          logger.success "image built"

          run "docker", "push", @release.docker_image.ref
          logger.fatal "image push failed" unless $?.success?
          logger.success "image pushed"
        end

        if @release.tag.state == :not_pushed
          logger.step "push tag (and accompanying git objects)"
          run "git", "push", "origin", @release.tag.name
          @release.tag.state = :pushed
        end
      end
    end

    if @options.deploy
      deploy_cmd.options.tag = @release.tag.name
      deploy_cmd.execute
    end
  end

  def burn_in_release
    [
      self.burn_in_project_templates,
      self.burn_in_sealed_secrets,
      self.burn_in_base_kustomization
    ].flatten
  end

  def burn_in_project_templates
    template_paths = @context.project.template_paths

    template_paths.each do |template_path|
      patched_doc =
        template_path.read
        .gsub(/\blatest\b/, @release.tag.name)
        .gsub(/\bmaster\b/, @release.from_git_branch)
        .gsub(/\b0000000000000000000000000000000000000000\b/, @release.from_git_ref)

      template_path.open('w'){ |f| f.write(patched_doc) }
    end

    template_paths
  end

  def burn_in_sealed_secrets
    sss_dir = @context.project.sealed_secrets_store
    return [] unless sss_dir

    shared_sealed_secret_docs =
      sss_dir.children
      .filter{ |f| f.file? and f.basename.to_s[0] != '.' }
      .flat_map{ |f| YAML.load_stream(f.read) }
      .filter{ |doc| doc['kind'] == 'SealedSecret' }
      .sort_by{ |doc| doc['metadata']['name'] }

    return [] if shared_sealed_secret_docs.empty?

    env_sealed_secrets_paths =
      (@context.application.k8s_resources / 'envs').children
      .filter{ |d| d.directory? and d.basename.to_s[0] != '.' }
      .map{ |d| d / 'sealed-secrets.yaml' }
      .filter{ |f| f.file? }

    return [] if env_sealed_secrets_paths.empty?

    env_sealed_secrets_paths.each do |env_ss_path|
      d_env = @context.application.deploy_environments[env_ss_path.parent.basename.to_s.intern]

      env_ss_doc_stream =
        shared_sealed_secret_docs
        .map{ |doc| sealed_secret_apply_namespace(d_env.k8s_namespace, doc) }
        .map{ |doc| doc.to_yaml }
        .join("")

      env_ss_path.open('w'){ |f| f.write(env_ss_doc_stream) }
    end

    env_sealed_secrets_paths
  end

  def burn_in_base_kustomization
    kustomization_path = @context.application.k8s_resources / 'base' / 'kustomization.yaml'
    kustomization_doc = YAML.load(kustomization_path.read)
    kustomization_doc['images'] ||= []
    kustomization_doc['images'].push({
      "name" => @release.docker_image.name,
      "newTag" => @release.tag.name
    })
    kustomization_path.open('w'){ |io| io.write(kustomization_doc.to_yaml) }

    [kustomization_path]
  end

  def sealed_secret_apply_namespace(ns, doc)
    doc['metadata']['namespace'] = ns
    doc['spec']['template']['metadata']['namespace'] = ns
    doc
  end

  def on_temporary_branch(new_branch, prev_ref)
    begin
      logger.step "create a temporary release branch from current ref"
      run "git", "checkout", "-b", new_branch
      yield
    ensure
      self.ensure_cleanup_step_emitted
      run "git", "checkout", prev_ref
      logger.success "return to previously-checked-out git ref"

      run "git", "branch", "-D", new_branch
      logger.success "delete temporary release branch"
    end
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
