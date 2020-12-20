require 'pathname'
require 'orbital/converger/cmd_runner'

class GCloud < CmdRunner
  def initialize(credentials_store_path)
    super()
    @credentials_store_path = credentials_store_path
  end

  def ensure_key_for_service_account!(service_account)
    creds_path = @credentials_store_path / "#{service_account}.json"

    return creds_path if creds_path.file?

    @credentials_store_path.mkpath

    self.run_command!(
      :gcloud, :iam, :"service-accounts", :keys, :create,
      creds_path.to_s,
      iam_account: service_account
    )

    creds_path
  end
end
