require 'pathname'
require 'yaml'

class Pathname
  def modify_as_yaml
    docs = YAML.load_stream(self.read)
    new_docs = yield(docs)
    new_stream = new_docs.map{ |doc| doc.to_yaml }.join("")
    self.open('w'){ |f| f.write(new_stream) }
  end
end
