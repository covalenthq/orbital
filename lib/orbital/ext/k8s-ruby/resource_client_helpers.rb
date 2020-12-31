require 'k8s-ruby'

class K8s::ResourceClient
  def member?(rc_name)
    begin
      self.get(rc_name)
      true
    rescue K8s::Error::NotFound
      false
    end
  end

  def maybe_get(rc_name)
    begin
      self.get(rc_name)
    rescue K8s::Error::NotFound
      nil
    end
  end
end
