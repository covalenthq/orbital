require 'pathname'

require_relative 'cmd_runner'
require_relative 'to_version'

class Helm < CmdRunner
  def best_available_version(chart_spec, namespace: :default, version_constraint: nil)
    kwargs = version_constraint ? {version: version_constraint} : {}
    doc = self.run_command_for_json!(:helm, :search, :repo, chart_spec, versions: true, output: :json, **kwargs)
    doc.map{ |ch| ch['version'].to_version }.sort.last
  end

  def deployed_releases
    @deployed_releases ||= self.fetch_deployed_releases!()
  end

  def available_update_for_deployed_release(rel_name, chart_spec, namespace: :default, version_constraint: nil)
    rel_id = release_id(namespace, rel_name)
    deployed_release = self.deployed_releases[rel_id] || {chart_version: Gem::Version.new('0.0.0')}
    deployed_chart_version = deployed_release[:chart_version]
    available_chart_version = best_available_version(chart_spec, namespace: namespace, version_constraint: version_constraint)

    info_symbol = colorize("@@", :blue)

    puts "\n#{info_symbol} For release #{colorize(rel_id, :bold)}, chart #{colorize(chart_spec, :bold)}:"
    puts "     deployed version:       #{colorize(deployed_chart_version.to_s, :bold)}"
    puts "     best available version: #{colorize(available_chart_version.to_s, :bold)}"

    if available_chart_version > deployed_chart_version
      available_chart_version
    else
      nil
    end
  end

  def ensure_deployed(rel_name, chart_spec, namespace: :default, version_constraint: nil, config_map: {})
    update_version = available_update_for_deployed_release(rel_name, chart_spec, namespace: namespace, version_constraint: version_constraint)
    return unless update_version

    flags = config_map.map do |k, v|
      k = k.to_s.tr('_', '-')
      ["--set", "#{k}=#{v}"]
    end.flatten

    kwargs = {
      atomic: true,
      cleanup_on_fail: true,
      create_namespace: true,
      install: true,
      version: update_version.to_s,
      wait: true
    }
    kwargs[:namespace] = namespace if namespace and namespace != :default

    self.run_command!(:helm, :upgrade, rel_name, chart_spec, *flags, **kwargs)
  end

  def register_repos(repo_specs)
    repo_specs.each do |repo_name, repo_uri|
      self.run_command!(:helm, :repo, :add, repo_name, repo_uri)
    end

    self.run_command!(:helm, :repo, :update)
  end

private

  def fetch_deployed_releases!
    doc = self.run_command_for_json!(:helm, :list, all_namespaces: true, output: :json)
    doc.map do |r|
      rel_id = release_id(r['namespace'], r['name'])
      chart_ver_str = r['chart'].split('-').last
      chart_name = r['chart'][0 ... -(chart_ver_str.length + 1)]
      [rel_id, {chart_name: chart_name, chart_version: chart_ver_str.to_version}]
    end.to_h
  end

  def release_id(rel_ns, rel_name)
    "#{rel_ns}/#{rel_name}"
  end
end
