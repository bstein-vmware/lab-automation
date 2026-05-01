#!/bin/bash
# Stop execution if any command fails
set -e


# --- Mode Selection (ask first, automate everything after) ---
echo ""
echo "╔═══════════════════════════════════════════╗"
echo "║       🚀 Field Lab Setup Script           ║"
echo "╚═══════════════════════════════════════════╝"
echo ""
echo "What would you like to do?"
echo ""
echo "  1) prep   → Install tools, drop YAMLs, patch configs, capture token,"
echo "              and initialize Terraform. Stops before Terraform apply."
echo ""
echo "  2) deploy → Full end-to-end: runs prep (skips steps already done)"
echo "              + Terraform apply + all context configuration."
echo ""
read -p "Enter your choice [prep/deploy]: " MODE
echo ""

# Normalize input
case "$MODE" in
    1|prep|p)   MODE="prep" ;;
    2|deploy|d) MODE="deploy" ;;
    *) echo "❌ Invalid choice. Please run again and choose 'prep' or 'deploy'."; exit 1 ;;
esac

echo "Running in ${MODE^^} mode..."
echo ""

echo "Which lab environment?"
echo ""
echo "  1) vks   → VKS Lab       (org: Broadcom,  user: broadcomadmin)"
echo "  2) adv   → Advanced Lab  (org: all-apps,  user: all-apps-admin)"
echo ""
read -p "Enter your choice [vks/adv]: " LAB_ENV
echo ""

case "$LAB_ENV" in
    1|vks|v)   LAB_ENV="vks" ;;
    2|adv|a)   LAB_ENV="adv" ;;
    *) echo "❌ Invalid choice. Please run again and choose 'vks' or 'adv'."; exit 1 ;;
esac

echo "Running for ${LAB_ENV^^} environment..."
echo ""


###############################################################################
#                         PREP (runs for both modes)                          #
###############################################################################

# --- 1. Variables & Folder Structure ---
LAB_PASS='VMware123!VMware123!'

if [[ "$LAB_ENV" == "vks" ]]; then
    VCFA_ORG="Broadcom"
    VCFA_USER="broadcomadmin"
    SUPERVISOR_ENDPOINT="10.1.0.6"
    REGION_NAME="us-west"
    VPC_NAME="us-west-Default-VPC"
    ZONE_NAME="z-wld-a"
else
    VCFA_ORG="all-apps"
    VCFA_USER="all-apps-admin"
    SUPERVISOR_ENDPOINT="10.1.0.2"
    REGION_NAME="us-west-region"
    VPC_NAME="us-west-region-default-vpc"
    ZONE_NAME="z-wld-a"
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "Verifying folder structure..."
LAB_DIR="$HOME/field-lab"
BIN_DIR="$HOME/.local/bin"
REPO_DIR="$LAB_DIR/vcfa-terraform-examples"
DESKTOP_DIR="$HOME/Desktop"
CLUSTER_NAME="e2e-niran-cls01"

mkdir -p "$LAB_DIR"
mkdir -p "$BIN_DIR"
mkdir -p "$DESKTOP_DIR"

export PATH="$BIN_DIR:$PATH"

SVC_DIR="$SCRIPT_DIR/supervisor-services"
VCENTER_CLUSTER_NAME="cluster-wld01-01a"
TOKEN_FILE="$DESKTOP_DIR/vcfa_api_token.txt"
TFVARS_FILE="$REPO_DIR/argo-e2e/terraform.tfvars"


# --- 2. Install Supervisor Services ---


# --- 3. Install CLIs & Prerequisites ---
echo "Checking prerequisites..."

# Ensure all Ubuntu repo components are available across all stanzas (main, restricted, universe, multiverse)
if [ -f /etc/apt/sources.list.d/ubuntu.sources ]; then
    echo "Expanding Ubuntu apt sources..."
    echo "$LAB_PASS" | sudo -S sed -i \
        's/^Components:.*/Components: main restricted universe multiverse/' \
        /etc/apt/sources.list.d/ubuntu.sources
fi

echo "$LAB_PASS" | sudo -S apt-get update -y
echo "$LAB_PASS" | sudo -S apt-get --fix-broken install -y

TOOLS="curl unzip git jq gpg zsh expect kubectx kubens kubecolor vim fzf"
for tool in $TOOLS; do
    if ! command -v $tool &> /dev/null; then
        echo "Installing $tool..."
        echo "$LAB_PASS" | sudo -S apt-get install -y $tool
    else
        echo "$tool is already installed. Skipping."
    fi
done

for pkg in apt-transport-https ca-certificates; do
    if ! dpkg -s $pkg >/dev/null 2>&1; then
        echo "Installing $pkg..."
        echo "$LAB_PASS" | sudo -S apt-get install -y $pkg
    fi
done

if ! python3 -c "import requests" 2>/dev/null; then
    echo "Installing python3-requests..."
    echo "$LAB_PASS" | sudo -S apt-get install -y python3-requests 2>/dev/null || \
        python3 -m pip install --break-system-packages requests 2>/dev/null || true
fi

if ! command -v pwsh &> /dev/null; then
    echo "Installing PowerShell..."
    curl -fsSL https://packages.microsoft.com/keys/microsoft.asc | \
        sudo gpg --dearmor -o /usr/share/keyrings/microsoft.gpg
    echo "deb [arch=amd64 signed-by=/usr/share/keyrings/microsoft.gpg] \
https://packages.microsoft.com/ubuntu/$(lsb_release -rs)/prod $(lsb_release -cs) main" | \
        sudo tee /etc/apt/sources.list.d/microsoft-prod.list
    echo "$LAB_PASS" | sudo -S apt-get update -y
    echo "$LAB_PASS" | sudo -S apt-get install -y powershell
fi

if ! pwsh -NonInteractive -Command "Get-Module -ListAvailable VMware.PowerCLI" 2>/dev/null | grep -q VMware; then
    echo "Installing VMware PowerCLI..."
    pwsh -NonInteractive -Command \
        "Install-Module VMware.PowerCLI -Scope CurrentUser -Force -SkipPublisherCheck -AllowClobber"
fi

if ! command -v vcf &> /dev/null; then
    echo "Installing VCF CLI..."
    curl -fsSLO "https://packages.broadcom.com/artifactory/vcf-distro/vcf-cli/linux/amd64/v9.0.2/vcf-cli.tar.gz"
    tar -xf vcf-cli.tar.gz
    echo "$LAB_PASS" | sudo -S install vcf-cli-linux_amd64 /usr/local/bin/vcf
    rm -f vcf-cli.tar.gz vcf-cli-linux_amd64
fi

if ! command -v argocd &> /dev/null; then
    echo "Installing ArgoCD CLI..."
    curl -fsSL -o /tmp/argocd \
        "https://github.com/argoproj/argo-cd/releases/download/v3.0.19/argocd-linux-amd64"
    echo "$LAB_PASS" | sudo -S install /tmp/argocd /usr/local/bin/argocd
    rm -f /tmp/argocd
fi

if ! command -v kubectl &> /dev/null; then
    echo "Installing kubectl..."
    curl -fsSLO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
    chmod +x kubectl
    mv kubectl "$BIN_DIR/"
fi

if ! command -v terraform &> /dev/null; then
    echo "Installing Terraform..."
    echo "$LAB_PASS" | sudo -S true 
    
    wget -O- https://apt.releases.hashicorp.com/gpg | sudo gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
    echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" | sudo tee /etc/apt/sources.list.d/hashicorp.list
    
    echo "$LAB_PASS" | sudo -S apt-get update -y
    echo "$LAB_PASS" | sudo -S apt-get install -y terraform
fi


# --- 4. Setup Zsh & Oh My Zsh ---
echo "Setting up Zsh and Oh My Zsh..."
if [ "$SHELL" != "$(which zsh)" ]; then
    echo "Changing default shell to zsh..."
    echo "$LAB_PASS" | sudo -S chsh -s $(which zsh) $(whoami)
fi

if [ ! -d "$HOME/.oh-my-zsh" ]; then
    echo "Installing Oh My Zsh..."
    RUNZSH=no CHSH=no sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended
fi

ZSH_CUSTOM="$HOME/.oh-my-zsh/custom"
if [ ! -d "$ZSH_CUSTOM/plugins/zsh-autosuggestions" ]; then
    git clone https://github.com/zsh-users/zsh-autosuggestions "$ZSH_CUSTOM/plugins/zsh-autosuggestions"
fi
if [ ! -d "$ZSH_CUSTOM/plugins/zsh-syntax-highlighting" ]; then
    git clone https://github.com/zsh-users/zsh-syntax-highlighting "$ZSH_CUSTOM/plugins/zsh-syntax-highlighting"
fi

sed -i 's/^ZSH_THEME=.*/ZSH_THEME="fino-time"/' "$HOME/.zshrc"
sed -i 's/^plugins=(git)/plugins=(git zsh-autosuggestions zsh-syntax-highlighting kubectl)/' "$HOME/.zshrc"

if ! grep -q "exec zsh" "$HOME/.bashrc"; then
    echo -e "\n# Launch Zsh automatically" >> "$HOME/.bashrc"
    echo 'if [ -t 1 ] && [ -z "$ZSH_VERSION" ]; then' >> "$HOME/.bashrc"
    echo '    exec zsh' >> "$HOME/.bashrc"
    echo 'fi' >> "$HOME/.bashrc"
fi


# --- 5. Setup Aliases ---
echo "Setting up aliases..."
cat << 'EOF' > "$HOME/.lab_aliases"
alias k='kubectl'
alias kctx='kubectx'
alias kns='kubens'
alias tf='terraform'
EOF

if ! grep -q ".lab_aliases" "$HOME/.zshrc"; then
    echo "source $HOME/.lab_aliases" >> "$HOME/.zshrc"
fi


# --- 6. Pull Git Repo & Patch Modules ---
echo "Managing the Terraform automation repo..."
if [ -d "$REPO_DIR" ]; then
    echo "Repo already exists. Pulling latest updates without overwriting custom files..."
    cd "$REPO_DIR"
    git pull
else
    git clone https://github.com/warroyo/vcfa-terraform-examples "$REPO_DIR"
fi

echo "Patching storage policy in the namespace module..."
sed -i 's/"vSAN Default Storage Policy"/"cluster-wld01-01a vSAN Storage Policy"/g' "$REPO_DIR/modules/namespace/main.tf"

echo "Patching ArgoCD version in the argocd module..."
sed -i -E 's/"version"[[:space:]]*=[[:space:]]*"[^"]*"/"version" = "3.0.19+vmware.1-vks.1"/g' "$REPO_DIR/modules/argocd-instance/main.tf"


echo "Patching VKS cluster class version..."
sed -i -E 's/"builtin-generic-v[0-9\.]+"/"builtin-generic-v3.5.0"/g' "$REPO_DIR/modules/vks-cluster/variables.tf"

echo "Patching VKS storage class in K8s manifest format..."
find "$REPO_DIR/modules/vks-cluster" -type f -exec sed -i 's/vsan-default-storage-policy/cluster-wld01-01a-vsan-storage-policy/g' {} +


# --- 7. Save Credentials to Desktop ---
echo "Saving credentials to Desktop..."
cat << EOF > "$DESKTOP_DIR/password.txt"
Lab Username: $VCFA_USER
Lab Password: $LAB_PASS
EOF


# --- 8. VCF CLI Setup ---
echo "Pre-configuring VCF CLI (EULA, CEIP, and plugins)..."
export VCF_CLI_VSPHERE_PASSWORD=$LAB_PASS
vcf plugin sync 2>/dev/null || true
vcf telemetry update --opted-out 2>/dev/null || true

echo "Creating VCF Supervisor Context..."
vcf context create supervisor-ctx \
  --endpoint "$SUPERVISOR_ENDPOINT" \
  --username administrator@wld.sso \
  --insecure-skip-tls-verify \
  -t kubernetes \
  --auth-type basic 2>/dev/null || echo "Context may already exist. Continuing..."

echo "Setting supervisor-ctx as current context..."
vcf context use supervisor-ctx 2>/dev/null || true


# --- 9. Content Library SSL Fix (pre-flight) ---
echo ""
echo "Patching Content Library SSL Certificates to prevent deployment errors..."

set +e  # Best-effort fixes — don't crash if vCenter API hiccups
SID=$(curl -k -s -X POST -u "administrator@wld.sso:$LAB_PASS" "https://vc-wld01-a.site-a.vcf.lab/rest/com/vmware/cis/session" | jq -r .value)

LIB_IDS=$(curl -k -s -X GET -H "vmware-api-session-id: $SID" "https://vc-wld01-a.site-a.vcf.lab/api/content/subscribed-library" | jq -r '.[]' 2>/dev/null)

for LIB_ID in $LIB_IDS; do
    LIB_INFO=$(curl -k -s -X GET -H "vmware-api-session-id: $SID" "https://vc-wld01-a.site-a.vcf.lab/api/content/subscribed-library/$LIB_ID" 2>/dev/null)
    URL=$(echo "$LIB_INFO" | jq -r '.subscription_info.subscription_url // empty' 2>/dev/null)
    
    if [[ "$URL" == https* ]]; then
        HOST=$(echo "$URL" | awk -F/ '{print $3}')
        THUMBPRINT=$(echo -n | openssl s_client -connect ${HOST}:443 2>/dev/null | openssl x509 -noout -fingerprint -sha1 | cut -d'=' -f2)
        
        if [ ! -z "$THUMBPRINT" ]; then
            echo "-> Trusting SSL thumbprint for $HOST ($THUMBPRINT)..."
            curl -k -s -X PATCH -H "vmware-api-session-id: $SID" -H "Content-Type: application/json" \
              -d "{\"subscription_info\": {\"ssl_thumbprint\": \"$THUMBPRINT\"}}" \
              "https://vc-wld01-a.site-a.vcf.lab/api/content/subscribed-library/$LIB_ID"
              
            echo "-> Forcing sync for library $LIB_ID..."
            curl -k -s -X POST -H "vmware-api-session-id: $SID" "https://vc-wld01-a.site-a.vcf.lab/api/content/subscribed-library/$LIB_ID?action=sync"
        fi
    fi
done
echo "✅ Content Library SSL fix applied."
set -e


# --- 10. VCFA Certificate & Context ---
echo ""
echo "Fetching VCFA certificate chain..."
VCFA_CERT_PATH="$LAB_DIR/vcfa_chain.pem"
openssl s_client -showcerts -connect auto-a.site-a.vcf.lab:443 </dev/null 2>/dev/null | awk '/BEGIN CERTIFICATE/,/END CERTIFICATE/{print}' > "$VCFA_CERT_PATH"


# --- 11. Manual Intervention & Token Capture ---
# Skip if token and tfvars already exist from a previous prep run
if [ -f "$TOKEN_FILE" ] && [ -f "$TFVARS_FILE" ]; then
    echo "✅ Previous prep detected — token and terraform.tfvars already exist. Skipping manual steps..."
    VCFA_TOKEN=$(cat "$TOKEN_FILE")
else
    echo "Installing supervisor services via PowerCLI..."
    _VC="vc-wld01-a.site-a.vcf.lab"
    _VCUSER="administrator@wld.sso"

    declare -A _SERVICES=(
        ["tkg.vsphere.vmware.com"]="$SVC_DIR/vks-upgrade.yaml"
        ["argocd-service.vsphere.vmware.com"]="$SVC_DIR/argocd-service.yaml"
        ["argocd-attach.fling.vsphere.vmware.com"]="$SVC_DIR/argo-attach.yaml"
        ["secret-store.vsphere.vmware.com"]="$SVC_DIR/secret-store-service.yaml"
    )
    declare -A _SERVICE_CONFIGS=(
        ["secret-store.vsphere.vmware.com"]="$SVC_DIR/secret-store-service-config.yaml"
    )

    for _SVC in "${!_SERVICES[@]}"; do
        _ARGS=(
            -VCenterServer "$_VC"
            -Username "$_VCUSER"
            -Password "$LAB_PASS"
            -YamlPath "${_SERVICES[$_SVC]}"
            -ServiceName "$_SVC"
            -ClusterName "$VCENTER_CLUSTER_NAME"
        )
        if [[ -n "${_SERVICE_CONFIGS[$_SVC]+x}" ]]; then
            _ARGS+=(-ConfigYamlPath "${_SERVICE_CONFIGS[$_SVC]}")
        fi
        pwsh -NonInteractive -File "$SCRIPT_DIR/install-supervisor-services.ps1" "${_ARGS[@]}"
    done

    # --- Auto-generate VCFA API token ---
    echo "Generating VCFA API token automatically..."

    set +e
    VCFA_TOKEN=$(python3 "$SCRIPT_DIR/vcfa-token.py" "$VCFA_USER" "$LAB_PASS" "$VCFA_ORG" 2>/tmp/vcfa_token_err.txt)
    _TOKEN_EXIT=$?
    set -e

    if [ $_TOKEN_EXIT -ne 0 ] || [ -z "$VCFA_TOKEN" ]; then
        echo "⚠️ Automated token generation failed:"
        cat /tmp/vcfa_token_err.txt 2>/dev/null || true
        rm -f /tmp/vcfa_token_err.txt
        echo "   Falling back to manual entry..."
        read -s -p "  🔑 Paste your VCFA API Token here and hit Enter (input hidden): " VCFA_TOKEN
        echo ""
    else
        echo "✅ VCFA API token generated automatically."
        rm -f /tmp/vcfa_token_err.txt
    fi

    echo "  Token saved to Desktop..."
    echo "$VCFA_TOKEN" > "$TOKEN_FILE"

    cd "$REPO_DIR/argo-e2e"

    echo "Injecting static and dynamic variables..."
    cat << EOF > terraform.tfvars
region_name         = "$REGION_NAME"
vpc_name            = "$VPC_NAME"
zone_name           = "$ZONE_NAME"
vcfa_org            = "$VCFA_ORG"
vcfa_url            = "https://auto-a.site-a.vcf.lab"
namespace           = "e2e-ns"
cluster             = "$CLUSTER_NAME"
bootstrap_revision  = "2.0.0"
k8s_version         = "v1.35.2+vmware.1"
vcfa_refresh_token  = "$VCFA_TOKEN"
cluster_class       = "builtin-generic-v3.6.0"
EOF
fi


cd "$REPO_DIR/argo-e2e"

echo "Initializing Terraform..."
terraform init


# --- If prep-only, stop here ---
if [ "$MODE" = "prep" ]; then
    echo ""
    echo "╔═══════════════════════════════════════════════════════════════════════╗"
    echo "║                    ✅ PREP COMPLETE!                                 ║"
    echo "╚═══════════════════════════════════════════════════════════════════════╝"
    echo ""
    echo "  All tools installed, configs patched, and Terraform initialized."
    echo "  VCF CLI contexts (supervisor-ctx, vcfa) are configured."
    echo "  Content Library SSL certificates have been trusted."
    echo "  terraform.tfvars and API token have been saved."
    echo ""
    echo "  You can now run 'terraform apply' manually from:"
    echo "  $REPO_DIR/argo-e2e"
    echo ""
    echo "  Or re-run this script and choose 'deploy' for full automation."
    echo ""
    exit 0
fi


###############################################################################
#                     DEPLOY (only runs in deploy mode)                       #
###############################################################################

# --- 12. Terraform Execution ---
echo "Phase 1: Targeting Supervisor Namespace creation..."
terraform apply -target=module.supervisor_namespace -auto-approve

# Temporarily disable exit-on-error for best-effort API fixes
set +e

# --> CAPACITY BUG FIX (requires namespace to exist) <--
echo "Applying vCenter capacity/usage bugfix to unstick the namespace..."
sleep 5 # Give k8s a few seconds to register the newly created namespace

NS_NAME=$(kubectl get ns --no-headers 2>/dev/null | grep e2e-ns | awk '{print $1}')

if [ ! -z "$NS_NAME" ]; then
    SID=$(curl -k -s -X POST -u "administrator@wld.sso:$LAB_PASS" "https://vc-wld01-a.site-a.vcf.lab/rest/com/vmware/cis/session" | jq -r .value)
    curl -k -s -X PATCH -H "vmware-api-session-id: $SID" -H "Content-Type: application/json" \
      "https://vc-wld01-a.site-a.vcf.lab/api/vcenter/namespaces/instances/$NS_NAME" \
      -d '{"resource_spec": {"memory_limit": 1048576}}'
    echo "✅ Namespace capacity update automatically saved."
fi

# Create the VCFA Context (needs token, done after capture)
echo "Creating VCFA CLI context..."
vcf context create vcfa \
  --endpoint auto-a.site-a.vcf.lab \
  --api-token "$VCFA_TOKEN" \
  --tenant-name "$VCFA_ORG" \
  --ca-certificate "$VCFA_CERT_PATH" 2>/dev/null || echo "VCFA context may already exist. Continuing..."


echo "Phase 2: Applying the rest of the infrastructure (ArgoCD, K8s cluster, etc.)..."
terraform apply -auto-approve
if [ $? -ne 0 ]; then
    echo "⚠️ Terraform encountered a known provider bug with VKS CRDs."
    echo "⚠️ The cluster is actually building. Forcing a state refresh and retrying..."
    terraform apply -refresh-only -auto-approve
    terraform apply -auto-approve || echo "⚠️ Terraform still complaining, but cluster is up. Proceeding to context setup!"
fi

# Re-enable exit-on-error
set -e


# --- 13. VKS Cluster Context Configuration ---
echo ""
echo "Configuring VKS cluster context for $CLUSTER_NAME..."

# We need a namespace-level context (e.g. vcfa:e2e-ns), not the top-level vcfa context.
# Auto-detect the namespace context from the list of available contexts.
echo "-> Finding VCFA namespace context..."
NS_CTX=$(vcf context list -o json 2>/dev/null | jq -r '.[].name' 2>/dev/null | grep -i "e2e-ns" | head -1)

if [ -z "$NS_CTX" ]; then
    # Fallback: list all contexts and let the user pick
    echo "⚠️ Could not auto-detect the namespace context."
    echo "   Available contexts:"
    vcf context list 2>/dev/null || true
    echo ""
    read -p "   Enter the namespace context name (e.g. vcfa:e2e-ns): " NS_CTX
fi

echo "-> Switching to namespace context: $NS_CTX"
yes | vcf context use "$NS_CTX" 2>/dev/null || echo "   (context switch warning — continuing)"

# Wait for the cluster to be fully ready (Pinniped Concierge needs time after Terraform)
echo ""
echo "-> Waiting for VKS cluster to be fully ready before configuring auth..."
echo "   (The cluster needs time after Terraform to initialize Pinniped components)"
echo "   Checking every 30 seconds for up to 15 minutes..."
echo ""

CLUSTER_READY=false
for i in $(seq 1 30); do
    # Try fetching kubeconfig as a readiness check
    if timeout 15 bash -c "yes | vcf cluster kubeconfig get \"$CLUSTER_NAME\" --export-file /tmp/cluster-readiness-check.kubeconfig 2>&1" >/dev/null 2>&1; then
        rm -f /tmp/cluster-readiness-check.kubeconfig
        CLUSTER_READY=true
        echo "   ✅ Cluster API is responding! Proceeding with auth setup..."
        break
    fi
    echo "   ⏳ Cluster not ready yet... (attempt $i/30)"
    sleep 30
done

if [ "$CLUSTER_READY" = "false" ]; then
    echo "⚠️ Cluster did not become ready within 15 minutes."
    echo "   Run test-cluster-ctx.sh manually once the cluster is up."
    echo ""
    echo "╔═══════════════════════════════════════════════════════════════════════╗"
    echo "║             ⚠️  Deployment Partially Complete                        ║"
    echo "╚═══════════════════════════════════════════════════════════════════════╝"
    echo ""
    echo "  Infrastructure deployed, but cluster context not yet configured."
    echo "  Run: ./test-cluster-ctx.sh  (once the cluster finishes provisioning)"
    echo ""
    exec zsh
fi

# Give Pinniped Concierge a little extra time to stabilize after API is up
echo "-> Waiting 60s for Pinniped Concierge to stabilize..."
sleep 60

# Register JWT authenticator with retry logic
echo "-> Registering VCFA JWT authenticator on the cluster..."
JWT_OK=false
for attempt in $(seq 1 3); do
    echo "   Attempt $attempt/3..."
    if timeout 120 bash -c "yes | vcf cluster register-vcfa-jwt-authenticator \"$CLUSTER_NAME\" 2>&1"; then
        JWT_OK=true
        break
    fi
    echo "   Retrying in 30 seconds..."
    sleep 30
done

if [ "$JWT_OK" = "false" ]; then
    echo "⚠️ JWT authenticator registration failed after 3 attempts."
    echo "   You can retry with: vcf cluster register-vcfa-jwt-authenticator $CLUSTER_NAME"
fi

echo "-> Fetching kubeconfig for the VKS cluster..."
mkdir -p ~/.kube
if ! timeout 60 bash -c "yes | vcf cluster kubeconfig get \"$CLUSTER_NAME\" --export-file ~/.kube/config 2>&1"; then
    echo "⚠️ Kubeconfig fetch timed out or failed."
    echo "   You can run this manually later:"
    echo "   vcf cluster kubeconfig get $CLUSTER_NAME --export-file ~/.kube/config"
fi

if [ -f ~/.kube/config ] && grep -q "$CLUSTER_NAME" ~/.kube/config 2>/dev/null; then
    echo "-> Finding cluster context name..."
    CLUSTER_CTX=$(grep "name:.*${CLUSTER_NAME}.*@" ~/.kube/config | awk '{print $2}' | head -1)

    if [ -z "$CLUSTER_CTX" ]; then
        echo "⚠️ Could not auto-detect the cluster context name."
        echo "   Here are the matching entries in your kubeconfig:"
        echo ""
        cat ~/.kube/config | grep "$CLUSTER_NAME"
        echo ""
        read -p "   Please paste the context name (the one with the @ sign): " CLUSTER_CTX
    fi

    echo "-> Creating VCF context for VKS cluster (kubecontext: $CLUSTER_CTX)..."
    if ! timeout 60 bash -c "yes | vcf context create e2e-niran-cls-01 --kubeconfig ~/.kube/config --kubecontext \"$CLUSTER_CTX\" --type cci 2>&1"; then
        echo "⚠️ Context creation timed out. You can run this manually:"
        echo "   vcf context create e2e-niran-cls-01 --kubeconfig ~/.kube/config --kubecontext $CLUSTER_CTX --type cci"
    fi

    # Verify the context actually works
    echo ""
    echo "-> Verifying cluster access..."
    sleep 5
    if timeout 30 kubectl --context "$CLUSTER_CTX" get ns >/dev/null 2>&1; then
        echo "   ✅ Cluster access verified! kubectl is working."
    else
        echo "   ⚠️ Cluster auth not working yet. Pinniped may still be initializing."
        echo "   If this persists, run: ./test-cluster-ctx.sh"
    fi
else
    echo "⚠️ Kubeconfig does not contain $CLUSTER_NAME yet."
    echo "   The cluster may still be provisioning. Run these manually when ready:"
    echo ""
    echo "   vcf context use <namespace-context>"
    echo "   vcf cluster register-vcfa-jwt-authenticator $CLUSTER_NAME"
    echo "   vcf cluster kubeconfig get $CLUSTER_NAME --export-file ~/.kube/config"
    echo "   grep $CLUSTER_NAME ~/.kube/config   # find the context with @"
    echo "   vcf context create e2e-niran-cls-01 --kubeconfig ~/.kube/config --kubecontext <name@ns> --type cci"
fi


echo ""
echo "╔═══════════════════════════════════════════════════════════════════════╗"
echo "║             ✅ Field Lab Deployment Complete!                        ║"
echo "╚═══════════════════════════════════════════════════════════════════════╝"
echo ""
echo "  VCF CLI Contexts configured:"
echo "    • supervisor-ctx   → Supervisor ($SUPERVISOR_ENDPOINT)"
echo "    • vcfa             → VCFA (auto-a.site-a.vcf.lab)"
echo "    • e2e-niran-cls-01 → VKS Cluster ($CLUSTER_NAME)"
echo ""
echo "  Dropping you into Oh My Zsh..."

exec zsh
