require 'uri'
require 'base64'
require 'digest'

module Orbital; end
class Orbital::SecretManager; end
class Orbital::SecretManager::ManagedSecret; end

class Orbital::SecretManager::ManagedSecret::Part
  def self.load(doc, secret:, dirty: false)
    new(doc, secret: secret, dirty: dirty)
  end

  def self.create(key, secret:)
    new({'key' => key}, secret: secret, dirty: true)
  end

  def self.compute_preview(type, mask_set, value)
    case type
    when :URI
      uri = URI.parse(value)
      if mask_set.member?(:user) and uri.user
        uri.user = nil
      end
      if mask_set.member?(:password) and uri.password
        uri.password = nil
      end
      if mask_set.member?(:path_last) and uri.path
        uri.path = uri.path.gsub(/(\/[^\/]+)$/, '')
      end
      {masked: uri.to_s}
    else
      {size: value.to_s.bytesize}
    end
  end

  PREVIEW_DUMMY_ASCII = "b8a9ecaa737a4fbb82c183f36d28588e".freeze
  private_constant :PREVIEW_DUMMY_ASCII

  PREVIEW_DUMMY_SYMBOL = "✻".freeze

  PREVIEW_DUMMY_PRETTY = (PREVIEW_DUMMY_SYMBOL * 3).freeze
  private_constant :PREVIEW_DUMMY_PRETTY

  def self.dummy_masked_fields(type, mask_set, value)
    ascii_dummied =
      case type
      when :URI
        uri = URI.parse(value)
        if mask_set.member?(:user)
          uri.user = PREVIEW_DUMMY_ASCII
        end
        if mask_set.member?(:password)
          if uri.userinfo
            uri.password = PREVIEW_DUMMY_ASCII
          else
            uri.userinfo = ':' + PREVIEW_DUMMY_ASCII
          end
        end
        if mask_set.member?(:path_last)
          uri.path = [uri.path.chomp('/'), PREVIEW_DUMMY_ASCII].join('/')
        end
        uri.to_s
      else
        nil
      end

    ascii_dummied.gsub(PREVIEW_DUMMY_ASCII, PREVIEW_DUMMY_PRETTY)
  end

  def initialize(doc = {}, secret:, dirty: false)
    @secret = secret

    @key = doc['key']
    @description = doc['description']

    @type =
      if type = doc['type']
        type.intern
      else
        :Opaque
      end

    @sealed = !!(doc['sealed'])
    @compromised = !!(doc['compromised'])

    if @sealed
      @sealed_value_digest =
        if svd = doc['sealedValueDigest']
          Base64.decode64(svd)
        end

      @sealed_value_preview =
        if svp = doc['sealedValuePreview']
          svp.map{ |k, v| [k.intern, v] }.to_h
        end

      @sealed_value_parts =
        doc['sealedValueParts']
        .map{ |ns, data| [ns, Base64.decode64(data)] }.to_h
    else
      @plain_value = doc['value']
    end

    @preview_mask_fields =
      if pmf = doc['previewMaskFields']
        pmf.map{ |f| f.to_s.intern }
      end

    @revision = (doc['revision'] || 0).to_i
    @value_revision = (doc['valueRevision'] || 0).to_i

    @dirty = dirty
    @value_dirty = dirty
  end

  def deep_copy
    copy_inst = self.dup
    copy_inst.instance_eval do
      if @sealed_value_parts
        @sealed_value_parts = @sealed_value_parts.dup
      end
    end
    copy_inst
  end

  attr_reader :key

  attr_reader :description
  def description=(new_desc)
    @dirty = true
    @description = new_desc
  end

  attr_reader :type
  def type=(new_type)
    @dirty = true
    @type = new_type.to_s.intern
  end

  def value_digest
    raise ArgumentError, "only willing to digest for sealed values" unless @sealed
    @sealed_value_digest
  end

  DEFAULT_PREVIEW_MASK_FIELDS_BY_TYPE = {
    URI: [:password],
    Opaque: []
  }

  def effective_preview_mask_fields
    Set.new(@preview_mask_fields || DEFAULT_PREVIEW_MASK_FIELDS_BY_TYPE[@type] || [])
  end

  def preview_mask_fields=(fields)
    @preview_mask_fields = fields.map{ |f| f.to_s.intern }
  end

  def dirty?
    @dirty
  end

  def sealed?
    @sealed
  end

  def compromised?
    @compromised
  end

  attr_reader :revision
  attr_reader :value_revision

  def get_plain_value!
    raise ArgumentError, "secret is sealed" if @sealed
    @plain_value
  end

  def get_sealed_value!(in_namespace:)
    raise ArgumentError, "secret is not sealed" unless @sealed

    unless @sealed_value_parts.has_key?(in_namespace)
      raise ArgumentError, "secret was not sealed for namespace #{in_namespace}.inspect"
    end

    @sealed_value_parts[in_namespace]
  end

  def printable_value
    return [:literal, @plain_value] unless @sealed

    case @sealed_value_preview
    in nil
      [:special, "nil"]
    in {masked: masked}
      dummied = self.class.dummy_masked_fields(
        @type,
        self.effective_preview_mask_fields,
        masked
      )
      [:literal, dummied]
    in {size: 0}
      [:special, "empty"]
    in {size: 1}
      [:abstract, "1 byte"]
    in {size: n}
      [:abstract, "#{n} bytes"]
    else
      [:special, "unknown"]
    end
  end

  def value=(new_value)
    @dirty = true
    @value_dirty = true

    @compromised = false

    if @sealed
      @sealed_value_parts = nil
      @sealed_value_preview = nil
      @sealed_value_digest = nil
      @sealed = false
    end

    @plain_value = new_value.to_s
  end

  def reseal!(sealer: nil)
    sealer ||= @secret.sealer

    return seal!(sealer: sealer) unless @sealed

    @sealed_value_parts =
      @sealed_value_parts.map do |scope_label, ciphertext|
        resealed = sealer.reseal(ciphertext, scope_label)
        [scope_label, resealed]
      end.to_h

    true
  end

  def unseal!(sealer: nil)
    return false unless @sealed

    sealer ||= @secret.sealer

    scope_label, ciphertext = @sealed_value_parts.first
    plain_value = sealer.unseal(ciphertext, scope_label)

    self.value = plain_value

    true
  end


  def seal!(sealer: nil)
    return false if @sealed

    sealer ||= @secret.sealer

    @sealed_value_parts =
      @secret.seal_for_namespaces.map do |ns|
        # N.B. using a namespace-wide scope label is less secure than
        # using a strict scope label, but we want the generated Secret/SealedSecret
        # to have a digest suffix, and the ergonomics of partial updates on
        # multi-key Secrets with strict sealing and digest-suffixed names are
        # awful, so we just avoid the problem entirely by not encoding
        # the eventual secret name into the label
        scope_label = ns

        sealed = sealer.seal(@plain_value, scope_label)
        [scope_label, sealed]
      end.to_h

    @sealed_value_digest =
      Digest::SHA256.digest(@plain_value || '')[0, 4]

    @sealed_value_preview =
      self.class.compute_preview(
        @type,
        self.effective_preview_mask_fields,
        @plain_value
      )

    @plain_value = nil
    @sealed = true

    true
  end

  def update
    yield(self)
    self.commit!
  end

  def commit!
    if @value_dirty
      @value_revision += 1
      @value_dirty = false
    end

    if @dirty
      @revision += 1
      @dirty = false
    end

    self
  end

  def to_yaml_doc
    raise ArgumentError, "cannot generate YAML doc for dirty secret part" if @dirty

    doc = {'key' => @key}
    if @description
      doc['description'] = @description
    end
    if @type != :Opaque
      doc['type'] = @type.to_s
    end
    if @sealed
      doc['sealed'] = true
    end
    if @compromised
      doc['compromised'] = true
    end
    if @plain_value
      doc['value'] = @plain_value
    end
    if @sealed_value_parts
      doc['sealedValueParts'] =
        @sealed_value_parts.map{ |ns, data| [ns, Base64.encode64(data)] }.to_h
    end
    if @sealed_value_digest
      doc['sealedValueDigest'] =
        Base64.strict_encode64(@sealed_value_digest)
    end
    if @sealed_value_preview
      doc['sealedValuePreview'] =
        @sealed_value_preview.map{ |k, v| [k.to_s, v] }.to_h
    end
    if @preview_mask_fields and @preview_mask_fields != DEFAULT_PREVIEW_MASK_FIELDS_BY_TYPE[@type]
      doc['previewMaskFields'] = @preview_mask_fields.map(&:to_s).sort
    end
    if @revision
      doc['revision'] = @revision
    end
    if @value_revision
      doc['valueRevision'] = @value_revision
    end

    doc
  end

  def to_yaml
    self.to_yaml_doc.to_yaml
  end
end
