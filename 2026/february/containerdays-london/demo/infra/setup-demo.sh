#!/usr/bin/env bash
set -euo pipefail

# Creates a local kind cluster, bootstraps Cluster API with the vSphere provider,
# and installs Flux pointing at this repository's demo manifests.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}" )" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
KIND_CONFIG="$SCRIPT_DIR/kindconfig.yaml"
KUBECONFIG_DIR="$SCRIPT_DIR/../kubeconfigs"
FLUX_REPO_REL_PATH="2026/february/containerdays-london/demo/gitops/flux"
FLUX_REPO_ABS_PATH="$REPO_ROOT/$FLUX_REPO_REL_PATH"
KIND_CLUSTER_NAME="$(awk -F': ' '/^name:/ {print $2}' "$KIND_CONFIG" | tr -d '"[:space:]')"
KIND_CLUSTER_NAME="${KIND_CLUSTER_NAME:-capi-talk}"

if [[ ! -f "$KIND_CONFIG" ]]; then
  echo "Missing kind configuration: $KIND_CONFIG" >&2
  exit 1
fi
if [[ ! -d "$FLUX_REPO_ABS_PATH" ]]; then
  echo "Flux path $FLUX_REPO_REL_PATH not found in repo" >&2
  exit 1
fi

if [[ -z "${GITHUB_TOKEN:-}" ]]; then
  echo "Set GITHUB_TOKEN with a GitHub PAT that has repo access." >&2
  exit 1
fi

source clusterctl.env

ORIGIN_URL="$(git -C "$REPO_ROOT" remote get-url origin 2>/dev/null || true)"
if [[ -z "$ORIGIN_URL" ]]; then
  echo "Unable to determine git remote URL." >&2
  exit 1
fi
if [[ "$ORIGIN_URL" =~ github\.com[:/]{1}([^/]+)/([^/.]+)(\.git)?$ ]]; then
  GITHUB_OWNER="${BASH_REMATCH[1]}"
  GITHUB_REPO="${BASH_REMATCH[2]}"
else
  echo "Remote $ORIGIN_URL is not a GitHub repository." >&2
  exit 1
fi
GIT_BRANCH="$(git -C "$REPO_ROOT" rev-parse --abbrev-ref HEAD)"

if kind get clusters | grep -qx "$KIND_CLUSTER_NAME"; then
  echo "kind cluster $KIND_CLUSTER_NAME already exists; reusing"
else
  kind create cluster --config "$KIND_CONFIG"
fi

kind get kubeconfig --name "$KIND_CLUSTER_NAME" > "$KUBECONFIG_DIR/kind.kubeconfig"
chmod 600 "$KUBECONFIG_DIR/kind.kubeconfig"
export KUBECONFIG="$KUBECONFIG_DIR/kind.kubeconfig"

clusterctl init --infrastructure vsphere

FLUX_CMD=(
  flux bootstrap github
  --owner "$GITHUB_OWNER"
  --repository "$GITHUB_REPO"
  --branch "$GIT_BRANCH"
  --path "$FLUX_REPO_REL_PATH"
  --kubeconfig "$KUBECONFIG_DIR/kind.kubeconfig"
  --token-auth
)
if [[ "${FLUX_GITHUB_PERSONAL:-false}" == "true" ]]; then
  FLUX_CMD+=(--personal)
fi

"${FLUX_CMD[@]}"

# apply secrets

kubectl apply -f ../gitops/cluster/v1_secret_capi-demo.yaml
kubectl apply -f ../gitops/cluster/v1_secret_vsphere-config-secret.yaml
kubectl apply -f ../gitops/cluster/v1_secret_cloud-provider-vsphere-credentials.yaml
