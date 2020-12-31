class Object
  def to_flat_string
    self.to_s
  end
end

class String
  def to_flat_string
    self
  end
end

class Array
  def to_flat_string
    self.flatten.map(&:to_flat_string).join("")
  end
end
