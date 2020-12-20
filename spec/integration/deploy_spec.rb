RSpec.describe "`orbital deploy` command", type: :cli do
  it "executes `orbital help deploy` command successfully" do
    output = `orbital help deploy`
    expected_output = <<-OUT
Usage:
  orbital deploy

Options:
  -h, [--help], [--no-help]  # Display usage information

Command description...
    OUT

    expect(output).to eq(expected_output)
  end
end
