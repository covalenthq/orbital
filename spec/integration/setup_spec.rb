RSpec.describe "`orbital setup` command", type: :cli do
  it "executes `orbital help setup` command successfully" do
    output = `orbital help setup`
    expected_output = <<-OUT
Usage:
  orbital setup

Options:
  -h, [--help], [--no-help]  # Display usage information

Command description...
    OUT

    expect(output).to eq(expected_output)
  end
end
