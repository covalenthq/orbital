require 'pathname'

require 'orbital/secret_manager/managed_secret'

module Orbital; end

class Orbital::SecretManager
  def initialize(store_path: nil, get_sealer_fn: nil)
    if store_path and not store_path.kind_of?(Pathname)
      store_path = Pathname.new(store_path.to_s)
    end

    @store_path = store_path
    @persisted_secrets = nil
    @dirty_secrets = {}
    @get_sealer_fn = get_sealer_fn
    @seal_for_namespaces = nil
  end

  def sealer
    return @sealer if @sealer
    @sealer = @get_sealer_fn.call
    @get_sealer_fn = nil
    @sealer
  end

  def sealing_for_namespaces(namespaces)
    if block_given?
      begin
        prev = @seal_for_namespaces
        @seal_for_namespaces = namespaces
        yield(self)
      ensure
        @seal_for_namespaces = prev
      end
    else
      @seal_for_namespaces = namespaces
    end
  end

  attr_reader :seal_for_namespaces

  def persisted_secrets
    return @persisted_secrets if @persisted_secrets
    return {} unless @store_path and @store_path.directory?
    @persisted_secrets = load_all_from_store!
  end

  attr_reader :dirty_secrets

  def secrets
    self.persisted_secrets.merge(@dirty_secrets)
  end

  def with_secret(secret_name, create: false)
    secret =
      if @dirty_secrets.has_key?(secret_name)
        @dirty_secrets[secret_name]
      elsif self.persisted_secrets.has_key?(secret_name)
        @dirty_secrets[secret_name] =
          self.persisted_secrets[secret_name].deep_copy
      elsif create
        @dirty_secrets[secret_name] =
          Orbital::SecretManager::ManagedSecret.create(
            manager: self,
            name: secret_name,
            store_dir: @store_path
          )
      else
        raise ArgumentError, "no managed secret named '#{secret_name}'"
      end

    if block_given?
      result = yield(secret)
      secret.commit!
      result
    else
      secret
    end
  end

  def persist_all!
    dirty_secrets = @dirty_secrets
    @dirty_secrets = {}

    dirty_secrets.each do |secret_name, secret|
      secret.commit!
      if secret.deleted?
        secret.backing_path.unlink if secret.backing_path.file?
        @persisted_secrets.delete(secret_name)
        secret
      else
        secret.backing_path.open('w'){ |f| f.write(secret.to_yaml) }
        @persisted_secrets[secret_name] = secret
      end
    end
  end

  private
  def load_all_from_store!
    persisted_secret_paths =
      @store_path.children.find_all{ |f| f.file? and f.basename.to_s =~ /\.(yml|yaml)/i }

    persisted_secret_paths.map do |secret_path|
      secret = Orbital::SecretManager::ManagedSecret.load(manager: self, backing_path: secret_path)
      [secret.name, secret]
    end.to_h
  end
end
