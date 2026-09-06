#!/bin/sh

set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

# -----------------------------------------------------------------------------
# Version pins (07.09.2026)
# -----------------------------------------------------------------------------
CLUSTER_NAME=${CLUSTER_NAME:-local}
KIND_CONFIG=${KIND_CONFIG:-"${SCRIPT_DIR}/configs/kind.yaml"}

KIND_NODE_IMAGE=${KIND_NODE_IMAGE:-"kindest/node:v1.37.0"}
GATEWAY_API_VERSION=${GATEWAY_API_VERSION:-v1.6.2}
CILIUM_VERSION=${CILIUM_VERSION:-1.20.1}
FLUX_VERSION=${FLUX_VERSION:-v2.9.5}
ESO_CHART_VERSION=${ESO_CHART_VERSION:-2.10.0}
AIRFLOW_CHART_VERSION=${AIRFLOW_CHART_VERSION:-1.22.0}
COROOT_OPERATOR_VERSION=${COROOT_OPERATOR_VERSION:-0.9.10}

# Set RESET_CLUSTER=1 to replace an existing cluster.
RESET_CLUSTER=${RESET_CLUSTER:-0}

# Set RUN_CONNECTIVITY_TEST=1 for the full Cilium connectivity test.
RUN_CONNECTIVITY_TEST=${RUN_CONNECTIVITY_TEST:-0}

# Set INSTALL_COROOT=1 to deploy Coroot.
# Requires CONFIG_TASKSTATS in the node kernel — not available on WSL2.
INSTALL_COROOT=${INSTALL_COROOT:-0}

readonly SCRIPT_DIR
readonly CLUSTER_NAME KIND_CONFIG
readonly KIND_NODE_IMAGE GATEWAY_API_VERSION CILIUM_VERSION FLUX_VERSION
readonly ESO_CHART_VERSION AIRFLOW_CHART_VERSION COROOT_OPERATOR_VERSION
readonly RESET_CLUSTER RUN_CONNECTIVITY_TEST INSTALL_COROOT

log() {
  printf '\n\033[1;34m==> %s\033[0m\n' "$*"
}

die() {
  printf '\n\033[1;31mERROR: %s\033[0m\n' "$*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

detect_kind_provider() {
  if [ -n "${KIND_EXPERIMENTAL_PROVIDER:-}" ]; then
    log "Using configured kind provider: ${KIND_EXPERIMENTAL_PROVIDER}"
    return
  fi

  if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    log "Using Docker as kind provider"
    return
  fi

  if command -v podman >/dev/null 2>&1 && podman info >/dev/null 2>&1; then
    KIND_EXPERIMENTAL_PROVIDER=podman
    export KIND_EXPERIMENTAL_PROVIDER
    log "Using Podman as kind provider"
    return
  fi

  die "Neither a running Docker engine nor Podman installation was found."
}

cluster_exists() {
  kind get clusters 2>/dev/null | grep -Fxq "$CLUSTER_NAME"
}

wait_for_gateway_crds() {
  for crd in \
    gatewayclasses.gateway.networking.k8s.io \
    gateways.gateway.networking.k8s.io \
    httproutes.gateway.networking.k8s.io \
    referencegrants.gateway.networking.k8s.io
  do
    kubectl wait \
      --for=condition=Established \
      "crd/${crd}" \
      --timeout=120s
  done
}

install_cilium() {
  helm \
    upgrade \
    --install \
    cilium \
    oci://quay.io/cilium/charts/cilium \
    --version "$CILIUM_VERSION" \
    --namespace kube-system \
    --values "${SCRIPT_DIR}/configs/cilium.yaml" \
    --set-string "k8sServiceHost=${CLUSTER_NAME}-control-plane" \
    --wait \
    --timeout 10m
}

install_secrets_stack() {
  helm \
    upgrade \
    --install \
    external-secrets \
    oci://ghcr.io/external-secrets/charts/external-secrets \
    --version "$ESO_CHART_VERSION" \
    --namespace external-secrets \
    --create-namespace \
    --wait \
    --timeout 5m

  kubectl apply -f "${SCRIPT_DIR}/deploy/secrets/vault.yaml"

  kubectl wait \
    --namespace vault \
    --for=condition=complete \
    job/vault-bootstrap \
    --timeout=180s
}

install_airflow() {
  helm repo add apache-airflow https://airflow.apache.org >/dev/null
  helm repo update apache-airflow >/dev/null

  helm \
    upgrade \
    --install \
    airflow \
    apache-airflow/airflow \
    --version "$AIRFLOW_CHART_VERSION" \
    --namespace airflow \
    --create-namespace \
    --values "${SCRIPT_DIR}/configs/airflow.yaml" \
    --wait \
    --timeout 15m
}

install_coroot() {
  helm repo add coroot https://coroot.github.io/helm-charts >/dev/null
  helm repo update coroot >/dev/null

  helm \
    upgrade \
    --install \
    coroot-operator \
    coroot/coroot-operator \
    --version "$COROOT_OPERATOR_VERSION" \
    --namespace observability \
    --create-namespace \
    --wait \
    --timeout 10m

  kubectl apply -f "${SCRIPT_DIR}/deploy/observability/coroot.yaml"
}

main() {
  require_command kind
  require_command kubectl
  require_command helm
  require_command cilium
  require_command flux
  require_command grep

  [ -f "$KIND_CONFIG" ] || die "kind config not found: ${KIND_CONFIG}"

  detect_kind_provider

  if cluster_exists; then
    if [ "$RESET_CLUSTER" = "1" ]; then
      log "Deleting existing kind cluster: ${CLUSTER_NAME}"
      kind delete cluster --name "$CLUSTER_NAME"
    else
      die "Cluster '${CLUSTER_NAME}' already exists. Run RESET_CLUSTER=1 ./setup.sh to replace it."
    fi
  fi

  log "Creating kind cluster: ${CLUSTER_NAME}"
  kind create cluster \
    --name "$CLUSTER_NAME" \
    --config "$KIND_CONFIG" \
    --image "$KIND_NODE_IMAGE"

  kubectl config use-context "kind-${CLUSTER_NAME}" >/dev/null

  log "Installing Gateway API ${GATEWAY_API_VERSION} CRDs"
  kubectl apply --server-side \
    -f "https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/standard-install.yaml"
  wait_for_gateway_crds

  log "Installing Cilium ${CILIUM_VERSION}"
  install_cilium

  log "Waiting for Cilium and Kubernetes nodes"
  cilium status \
    --wait \
    --wait-duration 10m \
    >/dev/null

  cilium status

  kubectl wait \
    --for=condition=Ready \
    nodes \
    --all \
    --timeout=10m
  kubectl rollout status \
    --namespace kube-system \
    deployment/coredns \
    --timeout=5m

  if [ "$RUN_CONNECTIVITY_TEST" = "1" ]; then
    log "Running Cilium connectivity test"
    cilium connectivity test
  fi

  log "Installing Flux ${FLUX_VERSION} controllers"
  kubectl apply --server-side \
    -f "https://github.com/fluxcd/flux2/releases/download/${FLUX_VERSION}/install.yaml"

  kubectl wait \
    --namespace flux-system \
    --for=condition=Available \
    deployment \
    --all \
    --timeout=5m

  flux check

  log "Installing External Secrets ${ESO_CHART_VERSION} and Vault"
  install_secrets_stack

  log "Applying platform manifests"
  kubectl apply -k "${SCRIPT_DIR}/deploy"

  kubectl wait \
    --all-namespaces \
    --for=condition=Ready \
    externalsecret \
    --all \
    --timeout=120s

  log "Installing Airflow ${AIRFLOW_CHART_VERSION}"
  install_airflow

  if [ "$INSTALL_COROOT" = "1" ]; then
    log "Installing Coroot ${COROOT_OPERATOR_VERSION}"
    install_coroot
  fi

  log "Cluster setup completed"
  kubectl get nodes -o wide
  kubectl get pods --all-namespaces

  printf '\nVersions:\n'
  printf '  Kubernetes node:  %s\n' "$KIND_NODE_IMAGE"
  printf '  Gateway API:      %s\n' "$GATEWAY_API_VERSION"
  printf '  Cilium:           %s\n' "$CILIUM_VERSION"
  printf '  Flux:             %s\n' "$FLUX_VERSION"
  printf '  External Secrets: %s\n' "$ESO_CHART_VERSION"
  printf '  Airflow:          %s\n' "$AIRFLOW_CHART_VERSION"

  printf '\nEndpoints (Cilium Gateway, port 8081):\n'
  printf '  http://airflow.localhost:8081\n'
  printf '  http://rustfs.localhost:8081\n'
  printf '  http://vault.localhost:8081   (dev token: root)\n'
  printf '  http://hubble.localhost:8081\n'
  if [ "$INSTALL_COROOT" = "1" ]; then
    printf '  http://coroot.localhost:8081\n'
  fi

  printf '\nNext step:\n'
  printf '  docker build -t demo-data-pipeline:dev apps/pipeline\n'
  printf '  kind load docker-image demo-data-pipeline:dev --name %s\n' "$CLUSTER_NAME"
  printf '  kubectl apply -f apps/pipeline/pipeline_jobs.yaml\n\n'
}

main "$@"
