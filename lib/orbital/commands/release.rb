# frozen_string_literal: true

require 'ostruct'
require 'yaml'

require 'orbital/command'

module Orbital; end
module Orbital::Commands; end
class Orbital::Commands::Release < Orbital::Command
  def initialize(options)
    @options = OpenStruct.new(options)
    @options.imagebuild = @options.imagebuild.intern

    appctl_config_path = self.project_root / '.appctlconfig'

    unless appctl_config_path.file?
      fatal "orbital-deploy must be run under a Git worktree containing an .appctlconfig"
    end

    @appctl_config = YAML.load(appctl_config_path.read)

    project_orbital_config_path = self.project_root / '.orbital.yaml'

    @orbital_config =
      if project_orbital_config_path.file?
        YAML.load(project_orbital_config_path.read)
      else
        {}
      end
  end

  def validate_environment
    return if @environment_validated
    log :step, "ensure release environment is sane"

    case @options.imagebuild
    when :cloudbuild
      exec_exist! 'gcloud', [link_to(
        "https://cloud.google.com/sdk/docs/install",
        "install the Google Cloud SDK."
      ), '.']
    when :local
      exec_exist! 'docker', [link_to(
        "https://docs.docker.com/get-docker/",
        "install Docker"
      ), '.']
    end

    unless `git status --porcelain`.strip.empty?
      log :failure, "git worktree is dirty."
      fatal "Releases can only be built against a clean worktree. Please commit or discard your changes."
    end
    log :success, "git worktree is clean"

    @environment_validated = true
  end

  def execute(input: $stdin, output: $stdout)
    self.validate_environment

    deploy_cmd = nil

    if @options.deploy
      require_relative 'deploy'

      deploy_cmd = Orbital::Commands::Deploy.new(@options.to_h.merge({
        "env" => "staging",
        "tag" => "dummy"
      }))

      deploy_cmd.validate_environment
    end

    log :step, "collect release information"

    @release = OpenStruct.new

    @release.from_git_branch = `git branch --show-current`.strip
    @release.from_git_branch = nil if @release.from_git_branch.empty?
    @release.from_git_ref = `git rev-parse HEAD`.strip
    log :success, "get branch and/or ref to return to"

    config_path = self.project_root / @appctl_config['config_path']
    k8s_deployment_path = config_path / 'base' / 'deployment.yaml'
    deployment_doc = YAML.load(k8s_deployment_path.read)
    @release.docker_image = OpenStruct.new(
      name: deployment_doc['spec']['template']['spec']['containers'][0]['image'].split(":")[0]
    )
    log :success, "get name of Docker image used in k8s deployment config"

    @release.tag = OpenStruct.new(
      name: "v#{Time.now.strftime("%Y%m%d%H%M%S")}",
      pushed: false
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

      IO.popen(["git", "commit", "--file=-"], "r+") do |io|
        io.puts "Release #{@release.tag.name}\n"
        if @release.from_git_branch
          io.puts "Base branch: #{@release.from_git_branch}"
        end
        io.puts "Base commit: #{@release.from_git_ref}"
        io.close_write
        io.read
      end

      with_temporary_git_tag(@release.tag) do
        log :step, "build and push Docker image #{@release.docker_image.ref}"

        case @options.imagebuild
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

        log :step, "push tag (and accompanying git objects)"
        run "git", "push", "origin", @release.tag.name
        @release.tag.pushed = true
      end
    end

    if @options.deploy
      deploy_cmd.tag = @release.tag.name
      deploy_cmd.execute
    end
  end

  def burn_in_release_metadata
    project_template_paths =
      (@orbital_config['burn_in_release_metadata'] || [])
      .map{ |path_part| self.project_root / path_part }

    project_template_paths.each do |template_path|
      patched_doc =
        template_path.read
        .gsub(/\blatest\b/, @release.tag.name)
        .gsub(/\bmaster\b/, @release.from_git_branch)
        .gsub(/\b0000000000000000000000000000000000000000\b/, @release.from_git_ref)

      template_path.open('w'){ |f| f.write(patched_doc) }
    end

    config_path = self.project_root / @appctl_config['config_path']
    kustomization_path = config_path / 'base' / 'kustomization.yaml'
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
      log :success, "create a release tag"
      yield
    ensure
      self.ensure_cleanup_step_emitted
      unless release_tag.pushed
        run "git", "tag", "--delete", release_tag.name
        log :success, "delete release tag"
      end
    end
  end

  def ensure_cleanup_step_emitted
    return if @emitted_cleanup_step
    log :step, "clean up"
    @emitted_cleanup_step = true
  end

end
