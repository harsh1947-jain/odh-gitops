#!/bin/bash
# Pre-upgrade hook: migrate cert-manager from CCM management to Helm subchart.
#
# When upgrading from 3.5 (cert-manager managed by CCM) to 3.6 (cert-manager
# as Helm subchart), this hook:
#   1. Detects if cert-manager is CCM-managed via infrastructure.opendatahub.io/part-of label
#   2. Patches the KubernetesEngine CR to set certManager.managementPolicy=Unmanaged
#   3. Waits for CCM to clean up cert-manager resources before Helm takes over
#
# Expected env vars:
#   RELEASE_NAME      - Current Helm release name
#   RELEASE_NAMESPACE - Current Helm release namespace

set -euo pipefail

WAIT_TIMEOUT="${WAIT_TIMEOUT:-300}"

# Check if cert-manager-operator namespace exists at all.
if ! kubectl get namespace cert-manager-operator &>/dev/null; then
  echo "cert-manager-operator namespace not found; nothing to migrate."
  exit 0
fi

# Check if cert-manager is CCM-managed by looking for the infrastructure.opendatahub.io/part-of label.
# Only CCM-created resources carry this label. If absent, cert-manager was installed by
# another means (or is already Helm-owned) — nothing to migrate.
PART_OF=$(kubectl get serviceaccount cert-manager-operator-controller-manager \
  -n cert-manager-operator \
  -o jsonpath='{.metadata.labels.infrastructure\.opendatahub\.io/part-of}' 2>/dev/null || true)

if [[ -z "$PART_OF" ]]; then
  echo "cert-manager not CCM-managed (no infrastructure.opendatahub.io/part-of label); skipping migration."
  exit 0
fi

echo "Detected CCM-managed cert-manager (part-of=${PART_OF}). Starting migration..."

# Detect active provider KubernetesEngine CR.
KE_RESOURCE=""

for ke_type in azurekubernetesengines awskubernetesengines coreweavekubernetesengines; do
  if kubectl get "$ke_type" &>/dev/null 2>&1; then
    KE_NAME=$(kubectl get "$ke_type" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
    if [[ -n "$KE_NAME" ]]; then
      KE_RESOURCE="${ke_type}/${KE_NAME}"
      break
    fi
  fi
done

if [[ -z "$KE_RESOURCE" ]]; then
  echo "No KubernetesEngine CR found; cannot release cert-manager from CCM."
  exit 1
fi

echo "Found KubernetesEngine CR: ${KE_RESOURCE}"

# Patch KE CR to set certManager.managementPolicy=Unmanaged.
# This tells CCM to stop managing cert-manager and clean up its resources.
echo "Patching ${KE_RESOURCE}: certManager.managementPolicy → Unmanaged..."
kubectl patch "$KE_RESOURCE" --type=merge \
  -p '{"spec":{"dependencies":{"certManager":{"managementPolicy":"Unmanaged"}}}}' 2>&1

# Wait for CCM to remove the cert-manager operator deployment.
echo "Waiting for CCM to clean up cert-manager-operator deployment (timeout: ${WAIT_TIMEOUT}s)..."
ELAPSED=0
while [[ $ELAPSED -lt $WAIT_TIMEOUT ]]; do
  DEPLOY_COUNT=$(kubectl get deployments -n cert-manager-operator --no-headers 2>/dev/null | wc -l || echo "0")
  if [[ "$DEPLOY_COUNT" -eq 0 ]]; then
    echo "cert-manager-operator deployment removed."
    break
  fi
  sleep 5
  ELAPSED=$((ELAPSED + 5))
done

if [[ $ELAPSED -ge $WAIT_TIMEOUT ]]; then
  echo "ERROR: Timeout waiting for cert-manager-operator deployment to be removed."
  echo "Remaining deployments:"
  kubectl get deployments -n cert-manager-operator 2>/dev/null || true
  exit 1
fi

# Wait for CCM to remove cert-manager operand deployments.
echo "Waiting for CCM to clean up cert-manager deployments (timeout: ${WAIT_TIMEOUT}s)..."
ELAPSED=0
while [[ $ELAPSED -lt $WAIT_TIMEOUT ]]; do
  DEPLOY_COUNT=$(kubectl get deployments -n cert-manager --no-headers 2>/dev/null | wc -l || echo "0")
  if [[ "$DEPLOY_COUNT" -eq 0 ]]; then
    echo "cert-manager deployments removed."
    break
  fi
  sleep 5
  ELAPSED=$((ELAPSED + 5))
done

if [[ $ELAPSED -ge $WAIT_TIMEOUT ]]; then
  echo "ERROR: Timeout waiting for cert-manager deployments to be removed."
  echo "Remaining deployments:"
  kubectl get deployments -n cert-manager 2>/dev/null || true
  exit 1
fi

# Wait for CertManager CR to be deleted by CCM.
if kubectl get certmanager cluster &>/dev/null 2>/dev/null; then
  echo "Waiting for CertManager CR deletion (timeout: ${WAIT_TIMEOUT}s)..."
  ELAPSED=0
  while [[ $ELAPSED -lt $WAIT_TIMEOUT ]]; do
    if ! kubectl get certmanager cluster &>/dev/null 2>/dev/null; then
      echo "CertManager CR deleted."
      break
    fi
    sleep 5
    ELAPSED=$((ELAPSED + 5))
  done

  if [[ $ELAPSED -ge $WAIT_TIMEOUT ]]; then
    echo "ERROR: Timeout waiting for CertManager CR deletion."
    kubectl get certmanager cluster -o yaml 2>/dev/null || true
    exit 1
  fi
fi

echo "Migration complete. Helm will now install cert-manager as a subchart."
