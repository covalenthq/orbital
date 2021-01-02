require 'uri'

class URI::Generic
  def join(suffix_str)
    URI.parse(self.to_s + suffix_str)
  end
end
