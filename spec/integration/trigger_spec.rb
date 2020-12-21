RSpec.describe "`orbital trigger` command", type: :cli do
  it "executes `orbital help trigger` command successfully" do
    output = `orbital help trigger`
    expected_output = <<-OUT
Usage:
  orbital trigger

Options:
  -h, [--help], [--no-help]  # Display usage information

Command description...
    OUT

    expect(output).to eq(expected_output)
  end
end
