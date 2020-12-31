require 'k8s-ruby'

class K8s::ResourceClient
  def has?(name:)
    begin
      self.get(name)
      true
    rescue K8s::Error::NotFound => e
      false
    end
  end
end
