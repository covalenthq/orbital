# frozen_string_literal: true

require 'orbital/setup_task'

module Orbital; end
module Orbital::SetupTasks; end
module Orbital::SetupTasks::Local; end
class Orbital::SetupTasks::Local::InstallCACert < Orbital::SetupTask
  dependent_on :mkcert

  def execute(*)
    return if self.mkcert_client.paths[:cert].file?

    log :step, "creating and installing local CA cert"
    self.mkcert_client.ensure_cert_created!
  end
end
