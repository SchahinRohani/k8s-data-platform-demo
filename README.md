<div align="center">

<!-- <img src="docs/logo.png" alt="Logo" width="120"> -->

# Local Kubernetes Data Platform Demo

**A reproducible local Kubernetes environment for developing and evaluating a small containerized data platform.**

[![Kubernetes](https://img.shields.io/badge/Kubernetes-kind-326CE5?logo=kubernetes&logoColor=white)](https://kind.sigs.k8s.io/)
[![Cilium](https://img.shields.io/badge/CNI-Cilium-F8C517?logo=cilium&logoColor=black)](https://cilium.io/)
[![FluxCD](https://img.shields.io/badge/GitOps-FluxCD-5468FF?logo=flux&logoColor=white)](https://fluxcd.io/)
[![Airflow](https://img.shields.io/badge/Orchestration-Airflow-017CEE?logo=apacheairflow&logoColor=white)](https://airflow.apache.org/)
[![DuckDB](https://img.shields.io/badge/SQL-DuckDB-FFF000?logo=duckdb&logoColor=black)](https://duckdb.org/)
[![Nix](https://img.shields.io/badge/Reproducible-Nix%20Flakes-5277C3?logo=nixos&logoColor=white)](https://nixos.org/)

</div>

---

The demo runs an Apache Airflow pipeline in isolated Kubernetes pods. It loads raw CSV data into
S3-compatible object storage, transforms the data with DuckDB, and writes the aggregated result
back as Parquet.

The environment has been validated on macOS/ARM64 and Windows with WSL2.

### Table of Contents

- [Architecture](#architecture)
- [Stack](#stack)
- [Prerequisites](#prerequisites)
- [Quick Start](#quick-start)
- [Platform Endpoints](#platform-endpoints)
- [Secrets Management](#secrets-management)
- [Coroot on WSL2](#coroot-on-wsl2)
- [Resetting the Environment](#resetting-the-environment)
- [Scope](#scope)

## Architecture

The example pipeline consists of two sequential and independently executable steps:

1. **Seed** uploads a CSV dataset to the `raw` S3 bucket.
2. **Transform** reads the raw data, aggregates it with DuckDB, and writes Parquet output to the
   `processed` bucket.

Apache Airflow orchestrates both steps using the `KubernetesPodOperator`.

## Stack

- **Kind** for the local Kubernetes cluster
- **Cilium** for container networking and Kubernetes Gateway API support
- **FluxCD** controllers for GitOps reconciliation
- **Vault** for centralized secrets management
- **External Secrets Operator** for synchronizing Vault secrets into Kubernetes
- **Apache Airflow** for workflow orchestration
- **RustFS** as S3-compatible object storage
- **DuckDB** as the SQL transformation engine
- **Coroot** as an optional eBPF-based observability evaluation

## Prerequisites

- A running Docker-compatible container runtime
- [Nix](https://nixos.org/download/) with flakes enabled
- macOS, Linux, or Windows with WSL2

The Nix development environment provides the required command-line tools and pinned dependencies.

## Quick Start

Enter the reproducible development environment:

```bash
nix develop
```

Create the local cluster and install the platform components:

```bash
./setup.sh
```

The cluster itself comes up in under a minute. Pulling the platform images takes
several minutes and happens again whenever the cluster is recreated, since kind
nodes do not persist the image cache.


Build the pipeline image and load it into the Kind nodes:

```bash
docker build -t demo-data-pipeline:dev apps/pipeline
kind load docker-image demo-data-pipeline:dev --name local
```

Verify the cluster and deployed workloads:

```bash
kubectl get nodes
kubectl get pods --all-namespaces
```

The Airflow UI is available at <http://airflow.localhost:8081>.

Run the demo DAG from Airflow and verify that:

1. the seed pod completes successfully;
2. the transform pod starts after the seed step;
3. the resulting Parquet file is written to the `processed` bucket.

## Platform Endpoints

The local services are exposed through the Cilium Gateway on port `8081`:

| Service | URL |
| ------- | --- |
| Airflow | `http://airflow.localhost:8081` |
| RustFS  | `http://rustfs.localhost:8081` |
| Vault   | `http://vault.localhost:8081` |
| Hubble  | `http://hubble.localhost:8081` |

## Secrets Management

Vault stores the RustFS access credentials. External Secrets Operator authenticates against Vault
through the Kubernetes authentication method and synchronizes the credentials into the required
Kubernetes namespaces.

> [!WARNING]
> Vault intentionally runs in development mode for this local demo. The configured root token and
> in-memory storage are not suitable for production use.

## Coroot on WSL2

Coroot is optional and disabled by default.

Its node agent relies on eBPF and Linux task-accounting capabilities. The tested Microsoft WSL2
kernel `6.18.40.1-microsoft-standard-WSL2` does not provide the required `CONFIG_TASKSTATS` kernel
option. The remaining platform, including the complete Airflow pipeline, runs successfully under
WSL2.

Coroot can be enabled on a compatible host with:

```bash
INSTALL_COROOT=1 ./setup.sh
```

## Resetting the Environment

To replace an existing Kind cluster and recreate the complete environment:

```bash
RESET_CLUSTER=1 ./setup.sh
```

## Scope

The demo runs entirely from local manifests. FluxCD controllers are installed but not yet bound to
a source, so the platform components are applied directly during setup.

Continuous reconciliation of the `deploy/` directory is the intended next step and is not part of
this demo.