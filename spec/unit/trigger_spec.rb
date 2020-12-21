require 'orbital/commands/trigger'

RSpec.describe Orbital::Commands::Trigger do
  it "executes `trigger` command successfully" do
    output = StringIO.new
    options = {}
    command = Orbital::Commands::Trigger.new(options)

    command.execute(output: output)

    expect(output.string).to eq("OK\n")
  end
end
