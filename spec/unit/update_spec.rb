require 'orbital/commands/update'

RSpec.describe Orbital::Commands::Update do
  it "executes `update` command successfully" do
    output = StringIO.new
    options = {}
    command = Orbital::Commands::Update.new(options)

    command.execute(output: output)

    expect(output.string).to eq("OK\n")
  end
end
