require 'yaml'

require 'digest/base32'

require 'orbital/secret_manager/managed_secret/part'

module Orbital; end
class Orbital::SecretManager; end

class Orbital::SecretManager::ManagedSecret
  DOC_API_VERSION = 'orbital.covalenthq.com/v1'
  DOC_KIND = 'ManagedSecret'

  def self.load(manager:, backing_path:)
    doc = YAML.load(backing_path.read)
    raise ArgumentError, "unexpected apiVersion" unless doc['apiVersion'] == DOC_API_VERSION
    raise ArgumentError, "unexpected kind" unless doc['kind'] == DOC_KIND
    raise ArgumentError, "missing required field metadata.name" unless doc.dig('metadata', 'name')

    new(doc, manager: manager, backing_path: backing_path)
  end

  def self.create(manager:, name:, type: 'Opaque', store_dir:)
    doc = {
      'apiVersion' => DOC_API_VERSION,
      'kind' => DOC_KIND,
      'metadata' => {
        'name' => name,
      },
      'type' => type,
      'parts' => []
    }

    new(doc, manager: manager, store_dir: store_dir, dirty: true)
  end

  class << self
    private :new
  end

  def initialize(doc, manager:, backing_path: nil, store_dir: nil, dirty: false)
    @manager = manager
    @backing_path = backing_path
    @store_dir = store_dir

    @name = doc.dig('metadata', 'name')

    @meta_dirty = false
    @deleted = false
    @type = (doc['type'] || 'Opaque').intern

    @parts =
      (doc['parts'] || []).map do |part_doc|
        part = Orbital::SecretManager::ManagedSecret::Part.load(part_doc, secret: self, dirty: dirty)
        [part.key, part]
      end.to_h
  end

  def deleted?
    @deleted
  end

  attr_reader :type
  def type=(new_type)
    @meta_dirty = true
    @type = new_type.to_s.intern
  end

  def [](k)
    @parts[k]
  end

  def []=(k, v)
    part = (
      @parts[k] ||= Orbital::SecretManager::ManagedSecret::Part.create(k, secret: self)
    )

    part.value = v

    v
  end

  def define(k, v, type: :Opaque, seal: false, mask_fields: nil)
    self[k] = v
    part = @parts[k]
    part.type = type
    if mask_fields
      part.preview_mask_fields = mask_fields
    end
    part.seal! if seal
    part
  end

  def deep_copy
    copy_inst = self.dup
    copy_inst.instance_eval do
      @parts = @parts.map{ |k, v| [k, v.deep_copy] }.to_h
    end
    copy_inst
  end

  def sealer
    @manager.sealer
  end

  def seal_for_namespaces
    @manager.seal_for_namespaces
  end

  def parts_digest
    parts_manifest = @parts.map{ |part| "#{part.key}: #{part.digest}\n" }.join
    Digest::SHA256.base32digest(parts_manifest)[0, 6]
  end

  def name_with_digest
    [@name, self.parts_digest].join('-')
  end

  attr_accessor :name
  attr_reader :parts

  def dirty?
    @meta_dirty or @parts.values.any?(&:dirty?)
  end

  def sealing_state
    if @parts.values.all?(&:sealed?)
      :fully_sealed
    elsif @parts.values.any?(&:sealed?)
      :partially_sealed
    else
      :unsealed
    end
  end

  def backing_path
    return @backing_path if @backing_path
    raise ArgumentError, "name not set" unless self.name
    raise ArgumentError, "store_dir not set" unless @store_dir
    @backing_path = @store_dir / "#{self.name}.yaml"
  end

  def compromised?
    @parts.values.any?(&:compromised?)
  end

  def commit!
    @parts.values.each(&:commit!)
    @meta_dirty = false
    self
  end

  def delete!
    self.commit!
    @deleted = true
    self
  end

  def inspect
    sealed_part =
      case self.sealed_state
      in :fully_sealed; ' (sealed)'
      in :partially_sealed; ' (part-sealed)'
      in :unsealed; ''
      end

    "#<ManagedSecret #{@name}#{sealed_part}>"
  end

  def to_yaml_doc
    raise ArgumentError, "cannot generate YAML doc for dirty secret" if self.dirty?

    {
      'apiVersion' => DOC_API_VERSION,
      'kind' => DOC_KIND,
      'metadata' => {
        'name' => @name
      },
      'type' => @type.to_s,
      'parts' => @parts.values.map(&:to_yaml_doc)
    }
  end

  def to_yaml
    self.to_yaml_doc.to_yaml
  end
end
