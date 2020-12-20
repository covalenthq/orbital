require 'orbital/commands/release'

RSpec.describe Orbital::Commands::Release do
  it "executes `release` command successfully" do
    output = StringIO.new
    options = {}
    command = Orbital::Commands::Release.new(options)

    command.execute(output: output)

    expect(output.string).to eq("OK\n")
  end
end
