# Setting up VM scaling (Track 1)

One-time setup for the VM scaling proposer. See
`docs/superpowers/specs/2026-08-20-vm-scaling-track-1-design.md` for why it is shaped this way.

The design's central guarantee is that **the credential able to resize the VM cannot be issued
until a human approves**. That rests entirely on the configuration below rather than on any code,
so §5 re-verifies it rather than assuming it.

```bash
export RG=MEZINEU
export REPO=mezinster/encounter-engine
export SUB=$(az account show --query id -o tsv)
export VM_ID=$(az vm show -g $RG -n web --query id -o tsv)
export ISSUER=https://token.actions.githubusercontent.com
```

## 0. The subject format is NOT the one most documentation shows

This repository has GitHub's **immutable OIDC subject claims** enabled, so the subject GitHub
sends carries numeric IDs the plain form does not:

```
repo:mezinster@10500786/encounter-engine@1322568945:environment:production
     ^^^^^^^^^^^^^^^^^^ ^^^^^^^^^^^^^^^^^^^^^^^^^^
     owner login + id   repo name + id
```

An Azure federated credential matches its subject by **exact string**, so a credential registered
with `repo:mezinster/encounter-engine:environment:vm-resize` would never match anything. The
failure is opaque and arrives only at the first real run:
`AADSTS70021: No matching federated identity record found`.

Derive the IDs rather than copying them — a repository transfer or rename changes the login and
name but not the IDs, and a delete-and-recreate changes the IDs:

```bash
export OWNER_ID=$(gh api /repos/$REPO --jq .owner.id)
export REPO_ID=$(gh api /repos/$REPO --jq .id)
export SUBJECT_PREFIX="repo:$(echo $REPO | cut -d/ -f1)@${OWNER_ID}/$(echo $REPO | cut -d/ -f2)@${REPO_ID}"
echo "$SUBJECT_PREFIX"
```

Cross-check it against the credential that is already working in production:

```bash
az identity federated-credential list --identity-name ee-deploy-oidc -g $RG --query "[].subject" -o tsv
```

The two must share everything up to the final `:`. If they do not, stop — one of them is wrong,
and the deploy identity is the one known to work.

## 1. The reader identity

Runs unattended on a cron. Read-only, scoped to the one VM. Named to match the existing
`ee-deploy-oidc` convention.

```bash
az identity create -g $RG -n ee-vmscale-reader-oidc
READER_PRINCIPAL=$(az identity show -g $RG -n ee-vmscale-reader-oidc --query principalId -o tsv)
READER_CLIENT=$(az identity show -g $RG -n ee-vmscale-reader-oidc --query clientId -o tsv)

az role assignment create --assignee-object-id "$READER_PRINCIPAL" \
  --assignee-principal-type ServicePrincipal --role "Monitoring Reader" --scope "$VM_ID"
az role assignment create --assignee-object-id "$READER_PRINCIPAL" \
  --assignee-principal-type ServicePrincipal --role "Reader" --scope "$VM_ID"

az identity federated-credential create --name github-master \
  --identity-name ee-vmscale-reader-oidc -g $RG \
  --issuer "$ISSUER" \
  --subject "${SUBJECT_PREFIX}:ref:refs/heads/master" \
  --audiences api://AzureADTokenExchange
```

## 2. The operator identity

Exists only behind the reviewer gate. Its federated credential trusts the **environment**, not a
branch — which is what makes approval and authorisation the same act rather than two things that
merely usually agree.

```bash
az identity create -g $RG -n ee-vmscale-operator-oidc
OPERATOR_PRINCIPAL=$(az identity show -g $RG -n ee-vmscale-operator-oidc --query principalId -o tsv)
OPERATOR_CLIENT=$(az identity show -g $RG -n ee-vmscale-operator-oidc --query clientId -o tsv)

az role assignment create --assignee-object-id "$OPERATOR_PRINCIPAL" \
  --assignee-principal-type ServicePrincipal \
  --role "Virtual Machine Contributor" --scope "$VM_ID"

az identity federated-credential create --name github-vm-resize \
  --identity-name ee-vmscale-operator-oidc -g $RG \
  --issuer "$ISSUER" \
  --subject "${SUBJECT_PREFIX}:environment:vm-resize" \
  --audiences api://AzureADTokenExchange
```

## 3. The GitHub environment and secrets

**The environment must exist AND carry a required reviewer.** Without the reviewer it is an
ordinary environment, the gate is gone, and the workflow resizes unattended — the one outcome this
entire design exists to prevent.

```bash
gh api -X PUT /repos/$REPO/environments/vm-resize \
  -f "prevent_self_review=false" \
  -F "reviewers[][type]=User" \
  -F "reviewers[][id]=$OWNER_ID"
```

`prevent_self_review` is deliberately `false`: you are the sole maintainer, and `true` would mean
nobody could ever approve a run you triggered.

```bash
gh secret set AZURE_VMSCALE_READER_CLIENT_ID   --repo $REPO --body "$READER_CLIENT"
gh secret set AZURE_VMSCALE_OPERATOR_CLIENT_ID --repo $REPO --body "$OPERATOR_CLIENT"
```

`AZURE_TENANT_ID` and `AZURE_SUBSCRIPTION_ID` already exist for the deploy workflow and are reused.

## 4. The decision log issue

```bash
gh label create vm-scaling-log --repo $REPO --color 0e8a16 \
  --description "The VM scaling proposer's decision log"
gh issue create --repo $REPO --label vm-scaling-log \
  --title "VM scaling — decision log" \
  --body "Proposals and outcomes from .github/workflows/vm-scale.yml. Do not close: the workflow comments on the newest open issue carrying this label."
```

## 5. Verify the guarantee

Run all six. Any failure means the approval gate is not what the design claims.

```bash
# a. The environment has a required reviewer.
gh api /repos/$REPO/environments/vm-resize \
  --jq '.protection_rules[] | select(.type=="required_reviewers") | .reviewers[].reviewer.login'
# Expect: mezinster. Empty output means the gate does not exist.

# b. The operator identity trusts exactly one subject, and it is the environment.
az identity federated-credential list --identity-name ee-vmscale-operator-oidc -g $RG \
  --query '[].{name:name, subject:subject}' -o table
# Expect: exactly one row, ending :environment:vm-resize, with the numeric IDs.

# c. The reader holds no write role anywhere.
az role assignment list --assignee "$READER_PRINCIPAL" --all \
  --query '[].{role:roleDefinitionName, scope:scope}' -o table
# Expect: only "Monitoring Reader" and "Reader", both scoped to the web VM.

# d. Neither identity holds anything at subscription or resource-group scope.
for P in "$READER_PRINCIPAL" "$OPERATOR_PRINCIPAL"; do
  az role assignment list --assignee "$P" --all \
    --query "[?scope=='/subscriptions/$SUB' || scope=='/subscriptions/$SUB/resourceGroups/$RG']" -o tsv
done
# Expect: no output at all.

# e. The subject prefixes match the identity that already works.
az identity federated-credential list --identity-name ee-deploy-oidc -g $RG --query "[0].subject" -o tsv
az identity federated-credential list --identity-name ee-vmscale-operator-oidc -g $RG --query "[0].subject" -o tsv
# Expect: identical up to the final ':'.

# f. The reader can read what gather.sh needs.
az monitor metrics list --resource "$VM_ID" --metric "CPU Credits Remaining" \
  --interval PT1H --aggregation Maximum -o none && echo "metrics ok"
az monitor activity-log list --resource-id "$VM_ID" --offset 1d -o none \
  && echo "activity log ok" \
  || echo "activity log NOT readable as YOU -- see the note below"
```

**Check (f) tests your own credentials, not the reader identity's.** The reader is scoped to one
VM while the Activity Log is a subscription-level resource, so it can pass for you and fail for the
identity. There is no way to test the identity's own view without a workflow run — the first
scheduled run reports the truth in its verdict, because `gather.sh` emits
`activity_log_readable: false` and every verdict then carries a line saying the cooldown is not in
force. That is the designed signal; read the first run's output rather than assuming.

If it does report `false`, decide deliberately: accept running without the cooldown (loudly, and
the human gate still stands in front of every resize), or grant `Monitoring Reader` at subscription
scope and accept the wider read. Do not quietly widen it as a reflex.

## 6. Undo

```bash
az identity delete -g $RG -n ee-vmscale-reader-oidc
az identity delete -g $RG -n ee-vmscale-operator-oidc
gh secret delete AZURE_VMSCALE_READER_CLIENT_ID   --repo $REPO
gh secret delete AZURE_VMSCALE_OPERATOR_CLIENT_ID --repo $REPO
gh api -X DELETE /repos/$REPO/environments/vm-resize
```

Role assignments are removed with the identities. The label and the log issue can stay — they cost
nothing and hold the history.
