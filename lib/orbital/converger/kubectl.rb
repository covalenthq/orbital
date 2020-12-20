require 'pathname'
require 'json'

require 'orbital/converger/cmd_runner'

class Kubectl < CmdRunner
  def ensure_secret!(secret_type, secret_name, **kwargs)
    return if self.has_secret?(secret_name, **(kwargs.slice(:namespace)))
    self.create_secret!(secret_type, secret_name, **kwargs)
  end

  def has_secret?(secret_name, **kwargs)
    result = self.run_command_for_output!(
      :kubectl, :get, :secret, secret_name,
      "--ignore-not-found",
      **kwargs
    )

    result.strip.length > 0
  end

  def create_secret!(secret_type, secret_name, **kwargs)
    self.run_command!(
      :kubectl, :create, :secret, secret_type,
      secret_name,
      **kwargs
    )
  end

  def patch!(resource_type, resource_name, patch_doc)
    patch_json = patch_doc.to_json

    self.run_command!(
      :kubectl, :patch,
      resource_type,
      resource_name,
      '-p', patch_json
    )
  end
end
