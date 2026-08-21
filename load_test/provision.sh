#!/usr/bin/env bash
# load_test/provision.sh — create or destroy the throwaway k6 generator.
#
# az CLI, not Terraform: this repository has no Terraform, no Bicep and no ARM,
# and its only infrastructure code is ansible/ configuring an existing host.
# Terraform earns its keep on long-lived resources with drift to manage; this
# VM lives about two hours.
#
# The resource group is the point. `az vm delete` leaves the NIC, NSG, public
# IP and OS disk behind, quietly billing. Deleting the GROUP removes everything
# or fails loudly.
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
    az group delete --name "$RG" --yes --no-wait
    echo "deleting resource group $RG (async)"
    ;;
  *)
    echo "usage: $0 create|destroy" >&2; exit 64 ;;
esac
