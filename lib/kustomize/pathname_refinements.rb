require 'pathname'
require 'yaml'

module Kustomize; end

module Kustomize::PathnameRefinements
  RC_EXT_PAT = /\.(yaml|yml)$/i
  KUSTOMIZATION_FILENAME = 'kustomization.yaml'
  KUSTOMIZATION_FILENAME_PAT = /^kustomization\.(yaml|yml)$/i

  refine ::Pathname do
    def visible?
      self.basename.to_s[0] != '.'
    end

    def resource_config_file?
      self.file? and self.visible? and !!(self.basename.to_s =~ RC_EXT_PAT)
    end

    def kustomization_file?
      self.file? and self.visible? and !!(self.basename.to_s =~ KUSTOMIZATION_FILENAME_PAT)
    end

    def child_kustomization_file
      self / KUSTOMIZATION_FILENAME
    end

    def kustomization_dir?
      self.directory? and self.child_kustomization_file.file?
    end

    def all_rc_files_within
      self.all_rc_files_within_visit.flatten
    end

    def all_rc_files_within_visit
      if self.resource_config_file?
        [self]
      elsif self.directory?
        self.children.map{ |ch| ch.all_rc_files_within_visit }
      else
        []
      end
    end
  end
end
