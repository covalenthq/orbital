# frozen_string_literal: true

require 'ostruct'
require 'yaml'

require 'orbital/command'

module Orbital; end
module Orbital::Commands; end
class Orbital::Commands::Release < Orbital::Command
  def initialize(*args)
    super(*args)
    @options.imagebuild = @options.imagebuild.intern
  end

  def validate_environment!
    return if @environment_validated
    log :step, "ensure shell environment is sane for release"

    case @options.imagebuild
    when :github, :cloudbuild
      @environment.validate :cmd_gcloud do
        exec_exist! 'gcloud', [link_to(
          "https://cloud.google.com/sdk/docs/install",
          "install the Google Cloud SDK."
        ), '.']
      end
    when :local
      @environment.validate :cmd_docker do
        exec_exist! 'docker', [link_to(
          "https://docs.docker.com/get-docker/",
          "install Docker"
        ), '.']
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
        fatal "Releases can only be built against a clean worktree. Please commit or discard your changes."
      end
    end

    @environment.validate :has_appctlconfig do
      @environment.project.appctl!
      log :success, ["project is configured for appctl (", Paint[".appctlconfig", :bold], " is available)"]
    end

    @environment_validated = true
  end

  def execute(input: $stdin, output: $stdout)
    self.validate_environment!

    deploy_cmd = nil

    if @options.deploy
      require_relative 'deploy'

      deploy_cmd_opts = @options.dup.to_h.merge({
        env: "staging",
        tag: "dummy"
      })

      deploy_cmd = sibling_command(Orbital::Commands::Deploy, **deploy_cmd_opts)

      deploy_cmd.validate_environment!
    end

    log :step, "collect release information"

    @release = OpenStruct.new

    @release.from_git_branch = `git branch --show-current`.strip
    @release.from_git_branch = nil if @release.from_git_branch.empty?
    @release.from_git_ref = `git rev-parse HEAD`.strip
    log :success, "get branch and/or ref to return to"

    deployment = @environment.project.appctl.k8s_resource('base/deployment.yaml')
    @release.docker_image = OpenStruct.new(
      name: deployment.spec.template.spec.containers[0].image.split(":")[0]
    )
    log :success, "get name of Docker image used in k8s deployment config"

    @release.tag = OpenStruct.new(
      name: "v#{Time.now.strftime("%Y%m%d%H%M%S")}",
      state: :not_pushed
    )
    @release.docker_image.ref = "#{@release.docker_image.name}:#{@release.tag.name}"
    log :success, "generate a release name based on the current datetime (like GAE)"

    release_branch_name = "release-#{@release.tag.name}-tmp"
    return_target = @release.from_git_branch || @release.from_git_ref
    on_temporary_branch(release_branch_name, return_target) do
      log :step, "burn release metadata into codebase and k8s resources"
      modified_paths = self.burn_in_release_metadata()
      modified_paths.each do |path|
        run "git", "add", path.expand_path.to_s
      end

      log :step, "create a release commit, and tag it"
      log :spawn, "git commit"
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
        if @options.imagebuild == :github
          log :step, "push tag (and accompanying git objects)"
          run "git", "push", "origin", @release.tag.name
          @release.tag.state = :tentatively_pushed
        end

        log :step, "build and push Docker image #{@release.docker_image.ref}"

        case @options.imagebuild
        when :github
          gcloud_access_token = `gcloud auth print-access-token`.strip
          fatal "gcloud authentication error" unless $?.success?

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

          fatal "image build+push failed" unless trigger_cmd.execute
          @release.tag.state = :pushed
          log :success, "image built and pushed"
        when :cloudbuild
          run "gcloud", "builds", "submit", "--tag", @release.docker_image.ref, "."
          fatal "image build+push failed" unless $?.success?
          log :success, "image built and pushed"
        when :local
          run "docker", "build", "-t", @release.docker_image.ref, "."
          fatal "image build failed" unless $?.success?
          log :success, "image built"

          run "docker", "push", @release.docker_image.ref
          fatal "image push failed" unless $?.success?
          log :success, "image pushed"
        end

        if @release.tag.state == :not_pushed
          log :step, "push tag (and accompanying git objects)"
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

  def burn_in_release_metadata
    project_template_paths = @environment.project.template_paths

    project_template_paths.each do |template_path|
      patched_doc =
        template_path.read
        .gsub(/\blatest\b/, @release.tag.name)
        .gsub(/\bmaster\b/, @release.from_git_branch)
        .gsub(/\b0000000000000000000000000000000000000000\b/, @release.from_git_ref)

      template_path.open('w'){ |f| f.write(patched_doc) }
    end

    kustomization_path = @environment.project.appctl.k8s_resources / 'base' / 'kustomization.yaml'
    kustomization_doc = YAML.load(kustomization_path.read)
    kustomization_doc['images'] ||= []
    kustomization_doc['images'].push({
      "name" => @release.docker_image.name,
      "newTag" => @release.tag.name
    })
    kustomization_path.open('w'){ |io| io.write(kustomization_doc.to_yaml) }

    [kustomization_path] + project_template_paths
  end

  def on_temporary_branch(new_branch, prev_ref)
    begin
      log :step, "create a temporary release branch from current ref"
      run "git", "checkout", "-b", new_branch
      yield
    ensure
      self.ensure_cleanup_step_emitted
      run "git", "checkout", prev_ref
      log :success, "return to previously-checked-out git ref"

      run "git", "branch", "-D", new_branch
      log :success, "delete temporary release branch"
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
          log :success, "delete release tag (remote)"
        end
        run "git", "tag", "--delete", release_tag.name
        log :success, "delete release tag (local)"
      end
    end
  end

  def ensure_cleanup_step_emitted
    return if @emitted_cleanup_step
    log :step, "clean up"
    @emitted_cleanup_step = true
  end

end
