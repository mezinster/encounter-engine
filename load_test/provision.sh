#!/usr/bin/env bash
# load_test/provision.sh — create or destroy the throwaway k6 generator.
#
# az CLI, not Terraform: this repository has no Terraform, no Bicep and no ARM,
# and its only infrastructure code is ansible/ configuring an existing host.
# Terraform earns its keep on long-lived resources with drift to manage; this
# VM lives about two hours.
#
# The resource group is the point. `az vm delete` leaves the NIC, NSG, public
# IP and OS disk behind, quietly billing -- this VM leaves six resources, only
# one of which is the VM. What matters is that NOTHING survives a run, and that
# somebody checks rather than assumes; `destroy` below empties the group by id
# and then asserts it is empty. The group itself is permanent, so that CI's
# rights can be scoped to it instead of to the subscription -- see `destroy`.
set -euo pipefail

RG="${LOAD_TEST_RG:-encounter-loadgen}"
LOCATION="${LOAD_TEST_LOCATION:-westeurope}"
VM="loadgen"

case "${1:-}" in
  create)
    # The operator's own address, for the one inbound rule below. Same source
    # the deploy workflow uses (.github/workflows/deploy.yml:131).
    # `|| true` on the end, not just between the two curls: under `set -e`,
    # `X=$(a || b)` still aborts the script AT THE ASSIGNMENT if both `a` and
    # `b` fail, before the explicit check below ever runs -- the friendly
    # error message would be unreachable dead code. Confirmed directly:
    #   bash -c 'set -euo pipefail; X=$(false || false); echo "reached"'
    # prints nothing. The trailing `|| true` absorbs that exit so the check
    # on the next line is what actually fires.
    MY_IP="$(curl -fsS --max-time 10 https://api.ipify.org || curl -fsS --max-time 10 https://ifconfig.me || true)"
    [ -n "$MY_IP" ] || { echo "could not determine this machine's public IP" >&2; exit 1; }

    az group create --name "$RG" --location "$LOCATION" --output none

    # --nsg-rule NONE: do NOT generate the default allow-SSH-from-anywhere rule.
    # Azure's built-in DenyAllInBound then governs, so the box is closed until
    # the explicit rule below opens it to one address.
    #
    # This is not hygiene. The generator holds the manifest -- a live password
    # for every seeded captain and every level's answer codes.
    #
    # The public IP stays, and is for OUTBOUND only: Azure retired default
    # outbound access in September 2025, so a VM with no public IP and no NAT
    # gateway has no internet at all, and reaching the app is the whole job. A
    # Standard-SKU public IP is closed to inbound by default.
    az vm create \
      --resource-group "$RG" --name "$VM" \
      --image Ubuntu2404 --size Standard_B1s \
      --admin-username azureuser --generate-ssh-keys \
      --custom-data "$(dirname "$0")/cloud-init.yml" \
      --nsg-rule NONE --public-ip-sku Standard \
      --output table

    # One inbound rule, one address, mirroring the just-in-time hole the deploy
    # workflow punches for its runner and closes again in the same job.
    az network nsg rule create \
      --resource-group "$RG" --nsg-name "${VM}NSG" \
      --name ssh-from-operator --priority 900 \
      --direction Inbound --access Allow --protocol Tcp \
      --destination-port-ranges 22 \
      --source-address-prefixes "${MY_IP}/32" \
      --output none

    echo
    echo "Inbound: SSH from ${MY_IP}/32 only. Everything else denied."
    echo "If your address changes mid-session, re-run:"
    echo "  az network nsg rule update --resource-group $RG --nsg-name ${VM}NSG \\"
    echo "    --name ssh-from-operator --source-address-prefixes <new-ip>/32"
    echo
    echo "Copy the manifest up, then run k6 there:"
    echo "  scp <manifest.json> azureuser@<ip>:~/manifest.json"
    echo "  scp -r load_test azureuser@<ip>:~/"
    echo
    echo "The manifest carries live production credentials. It dies with the"
    echo "resource group -- run '$0 destroy' as soon as the run is over."
    ;;
  destroy)
    # Empties the group; does NOT delete it. Two reasons, and the second is
    # the one that actually protects you.
    #
    # 1. The group is permanent so that a role assignment can be SCOPED to it.
    #    `az group delete` takes the scope down with the resources, and
    #    recreating it afterwards needs resourceGroups/write at SUBSCRIPTION
    #    scope -- so keeping the old line would have meant handing CI
    #    subscription-wide Contributor, an identity that could then resize or
    #    delete the production VM. ee-deploy-oidc holds Contributor on this
    #    group and Network Contributor on one NSG, and that is all.
    #
    # 2. The old line was `az group delete --yes --no-wait` followed by an echo
    #    saying it was deleting. Fire and forget: a delete that FAILED left a
    #    VM billing and nothing ever noticed. The point of the group was never
    #    the group, it was the guarantee that nothing survives the run -- and
    #    that guarantee was being announced rather than checked. It is checked
    #    now, and a non-empty group is a non-zero exit.
    #
    # Deleted by id, in passes: `az resource delete` refuses a NIC still
    # attached to a VM or a disk still attached to a NIC, and the ordering is
    # not worth encoding when retrying is this cheap.
    for pass in 1 2 3 4 5; do
      ids="$(az resource list -g "$RG" --query "[].id" -o tsv)"
      [ -z "$ids" ] && break
      echo "pass ${pass}: $(printf '%s\n' "$ids" | wc -l) resource(s) left"
      # shellcheck disable=SC2086
      printf '%s\n' $ids | xargs -r -n1 az resource delete --ids >/dev/null 2>&1 || true
    done

    remaining="$(az resource list -g "$RG" --query "length(@)" -o tsv)"
    if [ "$remaining" != "0" ]; then
      echo "::error::${RG} still holds ${remaining} resource(s) after 5 passes -- THEY ARE BILLING" >&2
      az resource list -g "$RG" --query "[].{name:name,type:type}" -o table >&2
      echo "::error::delete them by hand: az group delete --name ${RG} --yes" >&2
      exit 1
    fi
    echo "$RG is empty"
    ;;
  *)
    echo "usage: $0 create|destroy" >&2; exit 64 ;;
esac
