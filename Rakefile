require 'pathname'
require 'find'
require 'erb'
require_relative 'converger/helm'
require_relative 'converger/kubectl'

class Pathname
  def descendants
    Find.find(self.to_s).lazy.map{ |path| Pathname.new(path) }
  end

  def descendant_files(match_pattern)
    self.descendants.find_all do |f|
      next(false) unless f.file?
      bname = f.basename.to_s
      next(false) if bname[0] == '.'
      bname =~ match_pattern
    end
  end
end

wd = Pathname.new(__FILE__).parent
k8s_resources_src_dir = wd / 'src'
k8s_resources_build_dir = wd / 'build'
k8s_resources_combined_dir = k8s_resources_build_dir / 'combined'

helm = Helm.new
k8s_combined_resources = Kubectl.new(k8s_resources_combined_dir)

task :clean do
  k8s_resources_build_dir.rmtree if k8s_resources_build_dir.directory?
  k8s_resources_combined_dir.mkpath
end

task default: [:secrets, :infra, :databases, :apps]

task :secrets do
  k8s_combined_resources[:secrets].apply_all!
end

def render_template!(target_path, source_path)
  template = source_path.read
  rendered = ERB.new(template, nil, '>').result(binding)
  target_path.open('w'){ |f| f.write(rendered) }
end

def concat_all_under(target_path, source_tree)
  source_paths = source_tree.descendant_files(/\.yaml$/i).sort
  merged_source = source_paths.map{ |f| [f.read, "\n"] }.flatten.join
  target_path.open('w'){ |f| f.write(merged_source) }
end

def sentinel_file(path)
  file(path) do |t|
    yield(t)

    path = Pathname.new(path)
    path.parent.mkpath
    path.open('w'){ |f| f.write('') }
  end
end

sentinel_file 'build/helm/repos' do |t|
  helm.register_repos({
    'stable' => 'https://charts.helm.sh/stable',
    'ingress-nginx' => 'https://kubernetes.github.io/ingress-nginx',
    'jetstack' => 'https://charts.jetstack.io'
  })
end

['lb', 'cert-manager'].each do |chart_name|
  sentinel_path = "build/helm/charts/#{chart_name}"

  task(:infra => [sentinel_path])
  file(sentinel_path => 'build/helm/repos')
end

sentinel_file('build/helm/charts/lb') do |t|
  helm.ensure_deployed 'lb', 'ingress-nginx/ingress-nginx'
end

sentinel_file('build/helm/charts/cert-manager') do |t|
  helm.ensure_deployed 'cert-manager', 'jetstack/cert-manager',
    namespace: 'cert-manager',
    version_constraint: '^1.0.3',
    config_map: {
      installCRDs: true
    }
end

[:infra, :databases, :apps].each do |task_name|
  combined_path = (k8s_resources_combined_dir / "#{task_name}.yaml")
  sentinel_path = (k8s_resources_combined_dir / "#{task_name}.deployed")
  sources_dir = k8s_resources_src_dir / task_name.to_s
  targets_dir = k8s_resources_build_dir / task_name.to_s

  sentinel_file(sentinel_path) do |t|
    k8s_combined_resources[task_name].apply_all!
  end

  task({task_name => [sentinel_path.to_s]})
  file({sentinel_path.to_s => [combined_path.to_s]})

  file(combined_path.to_s) do |t|
    mkdir_p(combined_path.parent.to_s, verbose: false)
    concat_all_under(combined_path, targets_dir)
  end

  sources_dir.children.each do |source_path|
    next unless source_path.file? and source_path.basename.to_s =~ /\.yaml$/
    target_path = targets_dir + source_path.basename
    file({combined_path.to_s => [target_path.to_s]})
    file({target_path.to_s => [source_path.to_s]}) do |t|
      mkdir_p(target_path.parent.to_s, verbose: false)
      render_template!(target_path, source_path)
    end
  end
end
