# frozen_string_literal: true

require 'orbital/setup_task'

module Orbital; end
module Orbital::SetupTasks; end
module Orbital::SetupTasks::Local; end
class Orbital::SetupTasks::Local::InstallCACert < Orbital::SetupTask
  dependent_on :mkcert

  def resolved?
    self.mkcert_client.paths[:cert].file?
  end

  def execute(*)
    logger.step "creating and installing local CA cert"
    self.mkcert_client.ensure_cert_created!
  end
end
