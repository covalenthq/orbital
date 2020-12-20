RSpec.describe "`orbital release` command", type: :cli do
  it "executes `orbital help release` command successfully" do
    output = `orbital help release`
    expected_output = <<-OUT
Usage:
  orbital release

Options:
  -h, [--help], [--no-help]  # Display usage information

Command description...
    OUT

    expect(output).to eq(expected_output)
  end
end
