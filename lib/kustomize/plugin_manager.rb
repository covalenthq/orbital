require 'kustomize/plugin'

class Kustomize::PluginManager
  def initialize(session:)
    @session = session
    @instances = {}
  end

  def get(api_version, kind)
    cache_key = [api_version, kind]
    cached_inst = @instances[cache_key]
    return cached_inst if cached_inst

    @instances[cache_key] = self.load(api_version, kind)
  end

  def load(api_version, kind)
      @session.load_paths
      .each{ |prefix| puts(prefix / api_version / "#{kind.downcase}.rb") }

    load_path =
      @session.load_paths
      .map{ |prefix| prefix / api_version / "#{kind.downcase}.rb" }
      .find{ |f| f.file? }

    raise ArgumentError, "unknown kustomize plugin #{kind}" unless load_path

    Class.new(Kustomize::Plugin)
    .tap{ |klass| klass.class_eval(load_path.read) }
  end
end
