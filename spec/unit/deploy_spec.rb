require 'orbital/commands/deploy'

RSpec.describe Orbital::Commands::Deploy do
  it "executes `deploy` command successfully" do
    output = StringIO.new
    options = {}
    command = Orbital::Commands::Deploy.new(options)

    command.execute(output: output)

    expect(output.string).to eq("OK\n")
  end
end
