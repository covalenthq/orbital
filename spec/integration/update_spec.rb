RSpec.describe "`orbital update` command", type: :cli do
  it "executes `orbital help update` command successfully" do
    output = `orbital help update`
    expected_output = <<-OUT
Usage:
  orbital update

Options:
  -h, [--help], [--no-help]  # Display usage information

Command description...
    OUT

    expect(output).to eq(expected_output)
  end
end
