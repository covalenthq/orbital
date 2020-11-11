require 'pathname'
require 'singleton'
require 'json'
require 'yaml'
require 'active_support/core_ext/hash/keys'

require_relative 'cmd_runner'

class KubeResourceManager < CmdRunner
  class EmptyResourceSet
    include Singleton

    def [](key)
      self
    end

    def to_a
      []
    end

    def apply_all!
      true
    end

    def exist?
      false
    end
  end

  class ResourceSet
    def initialize
      @children = {}
    end

    def [](key)
      if @children.has_key?(key)
        @children[key]
      else
        EmptyResourceSet.instance
      end
    end

    def []=(key, node)
      @children[key] = node
    end

    def ensure_subset_at(key)
      @children[key] ||= ResourceSet.new
    end

    def to_a
      @children.values.map(&:to_a).flatten
    end

    def apply_all!
      @children.values.each(&:apply_all!)
    end

    def exist?
      true
    end
  end

  class Resource
    def initialize(kubectl, path)
      @kubectl = kubectl
      @path = path
    end

    def [](key)
      EmptyResourceSet.instance
    end

    attr_reader :path

    def to_a
      [self]
    end

    def apply_all!
      self.apply!
    end

    def apply!
      @kubectl.apply_resource_at_path(@path)
    end

    def exist?
      true
    end
  end

  RESOURCE_EXT_PAT = /\.(yaml|yml)$/

  def initialize(resources_dir_path)
    super()
    unless resources_dir_path.kind_of?(Pathname)
      resources_dir_path = Pathname.new(resources_dir_path.to_s)
    end
    @resources_path = resources_dir_path
  end

  def resources
    @resources ||= build_resource_set!()
  end

  def [](key)
    self.resources[key]
  end

  def apply_all!
    self.resources.apply_all!
  end

  def apply_resource_at_path(path)
    self.run_command!(:kubectl, :apply, '-f', path)
  end

  def create_as(s_type, s_namespace, s_name)
    path = @resources_path / "#{s_name}.secret.yaml"
    return if path.file?

    string_data_parts = yield

    doc = {
      apiVersion: 'v1',
      kind: 'Secret',
      metadata: {
        namespace: s_namespace.to_s,
        name: s_name.to_s
      },
      type: 'Opaque',
      stringData: string_data_parts
    }.deep_stringify_keys!

    path.open('w'){ |f| f.write(doc.to_yaml) }
  end

  private
  def build_resource_set!
    resource_set = ResourceSet.new

    resource_files = @resources_path.expand_path.children
    resource_files = resource_files.filter do |f|
      f.file? and f.basename.to_s[0] != '.' and f.basename.to_s =~ RESOURCE_EXT_PAT
    end

    resource_files.each do |resource_path|
      key_path = resource_path.basename.to_s.gsub(RESOURCE_EXT_PAT, '').split('.').map{ |part| part.gsub('-', '_').intern }
      branches_part, leaf_part = key_path[0..-2], key_path[-1]
      pos = resource_set
      branches_part.each do |branch_key|
        pos = pos.ensure_subset_at(branch_key)
      end
      pos[leaf_part] = Resource.new(self, resource_path)
    end

    resource_set
  end
end
