require 'kustomize/emitter'
require 'kustomize/emitter/file_emitter'

require 'kustomize/pathname_refinements'
using Kustomize::PathnameRefinements

class Kustomize::Emitter::DirectoryEmitter < Kustomize::Emitter
  def initialize(source_path, session:)
    @session = session
    @source_path = source_path
  end

  def input_emitters
    return @input_emitters if @input_emitters

    maybe_ckf = @source_path.child_kustomization_file

    @input_emitters =
      if maybe_ckf.file?
        ckf_emitter = Kustomize::Emitter::FileEmitter.new(maybe_ckf, session: @session)
        [ckf_emitter]
      else
        @source_path.all_rc_files_within.flat_map do |rc_path|
          Kustomize::Emitter::FileEmitter.new(rc_path, session: @session)
        end
      end
  end
end
