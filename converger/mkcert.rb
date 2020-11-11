require 'pathname'

require_relative 'cmd_runner'

class MkCert < CmdRunner
  def initialize(certs_store_path)
    super()
    @cert_store_path = certs_store_path
  end

  def paths
    {
      cert: @cert_store_path / 'rootCA.pem',
      key: @cert_store_path / 'rootCA-key.pem'
    }
  end

  def ensure_cert_created!
    unless self.paths[:cert].file?
      self.create_cert!
    end
  end

  def create_cert!
    @cert_store_path.mkpath

    self.with_env({"CAROOT" => @cert_store_path.expand_path.to_s}) do
      self.run_command!(:mkcert, "-install")
    end
  end

  def cert_uploaded?(secret_name, **kwargs)
    result = self.run_command_for_output!(
      :kubectl, :get, :secret, secret_name,
      "--ignore-not-found",
      **kwargs
    )

    result.strip.length > 0
  end

  def ensure_cert_uploaded_to_cluster!(secret_name, **kwargs)
    return if self.cert_uploaded?(secret_name, **kwargs)
    self.upload_cert_to_cluster!(secret_name, **kwargs)
  end

  def upload_cert_to_cluster!(secret_name, **kwargs)
    self.ensure_cert_created!
    paths = self.paths

    self.run_command!(
      :kubectl, :create, :secret, :tls, secret_name,
      key: paths[:key],
      cert: paths[:cert],
      **kwargs
    )
  end
end
