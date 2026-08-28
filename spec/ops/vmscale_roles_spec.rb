# frozen_string_literal: true

require "spec_helper"
require "json"

# The custom role definitions ee-vmscale-operator-oidc holds, as files rather
# than as JSON pasted into a shell.
#
# Pasting was how they were created twice on 2026-08-28, and it is precisely
# where a quoting mistake yields a role that looks right in the terminal and
# grants something else. A role definition is the narrowest part of this
# system's security argument; it should be reviewable in a diff.
#
# These examples are cheap and they guard three different mistakes.
RSpec.describe "ops/vmscale/roles" do
  ROLES_DIR = File.expand_path("../../ops/vmscale/roles", __dir__)

  def role(name)
    JSON.parse(File.read(File.join(ROLES_DIR, name)))
  end

  describe "vm-resize-links.json" do
    subject(:definition) { role("vm-resize-links.json") }

    # `az vm resize` is a PUT on the VM, which revalidates the whole VM model.
    # Virtual Machine Contributor scoped to the VM covers the VM and nothing
    # else, so each LINKED resource needs its own grant: the managed disks it
    # writes and the NIC it joins. Both failures of 2026-08-28 were this, one
    # resource at a time.
    it "grants exactly the two linked-resource actions a resize revalidates" do
      expect(definition.fetch("Actions")).to contain_exactly(
        "Microsoft.Compute/disks/write",
        "Microsoft.Network/networkInterfaces/join/action"
      )
    end

    # The role is assigned at RESOURCE GROUP scope, which is what makes it
    # survive a disk being replaced. That breadth is only defensible while the
    # action list stays this short, so the emptiness is part of the argument
    # rather than boilerplate: no create, no delete, no read, no data plane.
    it "grants nothing else, which is what makes a resource-group scope defensible" do
      expect(definition.fetch("NotActions")).to be_empty
      expect(definition.fetch("DataActions")).to be_empty
      expect(definition.fetch("NotDataActions")).to be_empty
    end

    it "carries a name and a description a reviewer can act on" do
      expect(definition.fetch("Name")).to eq("VM Resize Links (vmscale)")
      expect(definition.fetch("Description")).not_to be_empty
    end
  end

  # THIS REPOSITORY IS PUBLIC. docs/runbooks/vm-scaling-setup.md derives the
  # subscription id at runtime (`export SUB=$(az account show --query id -o tsv)`)
  # rather than committing it, and a role file is the obvious place to undo that
  # by accident, because `az role definition create` wants a real scope and the
  # quickest way to make the file work is to paste one in.
  #
  # A subscription id is not a credential, but it is a targeting detail this
  # repository has so far chosen not to publish, and that choice should not be
  # reversible by someone making a file "just run".
  it "keeps real subscription ids out of every role file, placeholders instead" do
    files = Dir.glob(File.join(ROLES_DIR, "*.json"))
    expect(files).not_to be_empty

    files.each do |path|
      scopes = JSON.parse(File.read(path)).fetch("AssignableScopes")
      expect(scopes).not_to be_empty, "#{File.basename(path)} has no AssignableScopes"

      scopes.each do |scope|
        expect(scope).to include("__SUB__"),
                         "#{File.basename(path)} names a scope without the __SUB__ " \
                         "placeholder: #{scope.inspect}"
        expect(scope).not_to match(/\h{8}-\h{4}-\h{4}-\h{4}-\h{12}/),
                             "#{File.basename(path)} contains what looks like a real " \
                             "subscription id: #{scope.inspect}"
      end
    end
  end
end
