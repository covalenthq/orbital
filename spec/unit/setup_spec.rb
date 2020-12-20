require 'orbital/commands/setup'

RSpec.describe Orbital::Commands::Setup do
  it "executes `setup` command successfully" do
    output = StringIO.new
    options = {}
    command = Orbital::Commands::Setup.new(options)

    command.execute(output: output)

    expect(output.string).to eq("OK\n")
  end
end
