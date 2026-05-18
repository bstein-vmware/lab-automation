# Field Lab Automation

Welcome to the Field Lab automation project! This repository contains a fully automated bootstrapping script designed to take a completely clean Ubuntu desktop and transform it into a fully configured, ready-to-use VMware Cloud Foundation (VCF) / vSphere with Tanzu environment.

## 🚀 Quick Start

To get started, simply open your terminal and paste the following command. The script will ask you two quick questions (which mode and which lab environment) before kicking off the fully automated deployment:

```bash
echo 'VMware123!VMware123!' | sudo -S sed -i 's/^Components:.*/Components: main restricted universe multiverse/' /etc/apt/sources.list.d/ubuntu.sources && sudo apt update -y && sudo apt install -y git && cd ~/Downloads && git clone https://github.com/NiranEC77/lab-automation && cd lab-automation && chmod +x setup-lab.sh && ./setup-lab.sh
```

## 🎛️ Modes of Operation

The script starts by asking you two questions — which mode and which lab environment. After that, everything is automated.

### Lab Environments

| Choice | Org / Tenant | VCFA User | Supervisor Endpoint |
|--------|-------------|-----------|---------------------|
| `vks` | Broadcom | broadcomadmin | 10.1.0.6 |
| `adv` | all-apps | all-apps-admin | 10.1.0.2 |
| `9.1` | Acme-East-A | acme-east-a | 10.1.8.132 |

### `prep` — Install & Configure (stops before Terraform deploy)

Choose this when you want to get the environment ready while VKS upgrades and ArgoCD deployments are still installing in vCenter.

- Installs all CLIs & prerequisites
- Installs and activates supervisor services (VKS upgrade, ArgoCD, ArgoCD Attach, Secret Store, Harbor, and LCI) via PowerCLI
- Configures Zsh + Oh My Zsh
- Clones and patches the Terraform repo
- Automatically generates and stores your VCFA API token
- Writes `terraform.tfvars` and runs `terraform init`
- **Stops here** — does NOT run `terraform apply`

### `deploy` — Full End-to-End

Choose this for the complete flow. Deploy runs **all prep steps first** (skipping anything already done), then continues with:

- Terraform apply (namespace + full infrastructure)
- Automated vCenter API bug fixes
- VCF CLI context configuration (Supervisor, VCFA, and VKS cluster)
- Drops you into a fully authenticated Oh My Zsh terminal

> **Re-run friendly:** If prep was already completed, deploy detects the existing token and `terraform.tfvars` and skips straight to the Terraform and context setup phases.


## 🛠️ What This Script Does

### 1. Bootstrap (System Preparation)
* **Folder Structure:** Creates standard directories (`~/field-lab`, `~/.local/bin`, `~/Desktop`).
* **Package Management:** Expands Ubuntu APT sources, updates packages, and fixes broken dependencies.
* **Core Dependencies:** Installs `curl`, `unzip`, `git`, `jq`, `gpg`, `zsh`, `expect`, `kubectx`, `kubens`, `kubecolor`, and `fzf`.
* **VCF CLI:** Downloads and installs VCF CLI v9.0.2 from Broadcom.
* **ArgoCD CLI:** Downloads and installs ArgoCD CLI v3.0.19.
* **Infrastructure CLIs:** Downloads and installs the latest stable versions of kubectl and Terraform.
* **PowerShell & PowerCLI:** Installs PowerShell Core and VMware PowerCLI for supervisor service automation.

### 2. Supervisor Service Installation
* Upgrades VKS (Kubernetes Service).
* Deploys the ArgoCD Supervisor Service.
* Deploys the ArgoCD Attach Fling.
* Deploys the Secret Store Service (with storage class config).
* Deploys the Harbor Service (with lab password and storage class config).
* Deploys the LCI Service (Local Consumption Interface).
* Deploys the Supervisor Management Proxy Service for cluster Observability metrics into VCF Operations.
* Uses `install-supervisor-services.ps1` with the VMware.Sdk.vSphere 13.5.0 (9.x) SDK. The script handles new registration, version deduplication, **compatibility precheck** (polls until `COMPATIBLE` before proceeding), and cluster install/upgrade automatically. YAML manifests live in `supervisor-services/`.

### 3. Pimp the Terminal
* **Zsh Integration:** Installs `zsh` and sets it as your default shell.
* **Oh My Zsh:** Performs an unattended installation with the `fino-time` theme.
* **Productivity Plugins:** Auto-suggestions, syntax-highlighting, git, and kubectl autocomplete.
* **Aliases:** Persistent shortcuts — `k` for kubectl, `tf` for terraform.

### 5. Terraform Repo & Patching
* **Git Automation:** Clones the `vcfa-terraform-examples` repository.
* **On-the-fly Patching:** Automatically patches modules and injects Terraform variables:
  * Storage policy → `cluster-wld01-01a vSAN Storage Policy`
  * VKS cluster class → `builtin-generic-v3.6.0`
  * Kubernetes version → `v1.34.1+vmware.1`
  * ArgoCD version → `3.0.19+vmware.1-vks.1`
  * Storage class → `cluster-wld01-01a-vsan-storage-policy`

### 6. Terraform Execution
* **Phase 1:** Targeted apply for Supervisor Namespace creation.
* **Phase 2:** Full apply for ArgoCD instances, VKS clusters, and remaining infrastructure. It also sets the ArgoCD admin user password to be the same as the lab password.
* **Smart Retry:** Automatically handles the known VKS CRD provider bug with state refresh and retry logic.

### 7. Automated API Bug Fixes
* **Capacity Bug:** Uses the vCenter API to patch Namespace memory limits so the namespace doesn't get stuck.
* **Content Library SSL:** Detects and trusts Content Library SSL thumbprints, then forces a sync to prevent deployment hang-ups.

### 8. VCF CLI Context Configuration
The script automatically configures three VCF CLI contexts:

| Context | Type | Purpose |
|---------|------|---------|
| `supervisor-ctx` | Kubernetes | Supervisor cluster access (endpoint is env-specific) |
| `vcfa` | VCFA | VCFA org-level access (auto-a.site-a.vcf.lab) |
| `e2e-cls01` | CCI | VKS workload cluster access |

For the VKS cluster context, the script:
1. Auto-detects the VCFA namespace context (`e2e-ns`)
2. Polls until the cluster API is responding (up to 15 minutes)
3. Waits 60 seconds for Pinniped Concierge to stabilize
4. Registers the VCFA JWT authenticator (3 attempts with retry)
5. Fetches the kubeconfig and parses the context name

> If the cluster isn't ready by the time `deploy` completes, run `./ctx2.sh` once it is — it performs all of the above steps standalone without re-running the full setup.

> All VCF CLI commands include timeout protection, non-interactive basic auth handling, and automatic prompt handling to prevent the script from hanging.

### 9. Finish Up
* **Certificate Trust:** Downloads the VCFA SSL certificate chain for CLI trust.
* **API Token Management:** Automatically generates your VCFA refresh token via the VCFA OAuth API. The token is saved to `~/Desktop/vcfa_api_token.txt`, exported as `VCF_CLI_VCFA_API_TOKEN`, and persisted to `~/.zshrc` so it is available across sessions. Token generation only runs during the initial `setup-lab.sh` run — `ctx2.sh` reads the already-stored token.
* **Credentials:** Saves lab username/password to `~/Desktop/password.txt`.
* **Oh My Zsh:** Drops you into a fully authenticated, themed terminal when complete.

## 📁 Files in This Repo

| File | Description |
|------|-------------|
| `setup-lab.sh` | Main automation script (prep/deploy modes) |
| `ctx-lib.sh` | Shared library — environment picker, token management, VCFA context, and cluster context functions |
| `ctx2.sh` | Standalone script to (re)configure the VKS cluster context without re-running full setup |
| `install-supervisor-services.ps1` | PowerCLI script — supervisor service registration, precheck, install, and upgrade (SDK 9.x) |
| `vcfa-token.py` | Automated VCFA OAuth token generation |
| `README.md` | This file |

### `supervisor-services/`

| File | Description |
|------|-------------|
| `vks-upgrade.yaml` | VKS upgrade package YAML |
| `argocd-service.yaml` | ArgoCD Supervisor Service package YAML |
| `argo-attach.yaml` | ArgoCD Attach Fling package YAML |
| `secret-store-service.yaml` | Secret Store Service package YAML |
| `secret-store-service-config.yaml` | Secret Store Service install config (storage class) |
| `supervisor-management-proxy-service.yaml` | Supervisor Management Proxy Service package YAML |
| `harbor-service.yaml` | Harbor Service package YAML |
| `harbor-service-config.yaml` | Harbor Service install config (Harbor FQDN, lab password, and storage class) |
| `lci-service.yaml` | Local Consumption Interface Service package YAML |
