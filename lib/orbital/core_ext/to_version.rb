class NilClass
  def to_version
    Gem::Version.new('0.0.0')
  end
end

class String
  def to_version
    Gem::Version.new(self.gsub(/^v/, ''))
  end
end
