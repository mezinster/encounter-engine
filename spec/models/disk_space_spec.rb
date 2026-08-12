require "rails_helper"

describe DiskSpace do
  it "reports a positive number of megabytes for a real path" do
    expect(DiskSpace.available_megabytes(Rails.root.to_s)).to be > 0
  end

  it "parses df's output rather than trusting its formatting" do
    output = "Filesystem     1024-blocks     Used Available Capacity Mounted on\n" \
             "/dev/sda1         30832548 17000000   3145728      56% /\n"
    allow(DiskSpace).to receive(:df_output).and_return(output)

    expect(DiskSpace.available_megabytes("/anything")).to eq(3072)
  end

  it "returns 0 rather than raising when df cannot answer" do
    # A refusal to write is the safe failure. Returning a large number because
    # the probe broke would disable the floor exactly when it is needed.
    allow(DiskSpace).to receive(:df_output).and_return("")

    expect(DiskSpace.available_megabytes("/anything")).to eq(0)
  end
end
