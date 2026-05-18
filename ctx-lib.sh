#!/bin/bash
# Shared library for environment selection and VKS context configuration.
# Source this file — do not execute it directly.

VCFA_ENDPOINT="auto-a.site-a.vcf.lab"
CLUSTER_NAME="e2e-cls01"
LAB_PASS='VMware123!VMware123!'

# Sets VCFA_ORG, VCFA_USER, and all other env-specific vars from LAB_ENV.
# Callers must set LAB_ENV before calling, or call pick_environment first.
resolve_environment() {
    case "$LAB_ENV" in
        1|vks|v)
            LAB_ENV="vks"
            VCFA_ORG="Broadcom"
            VCFA_USER="broadcomadmin"
            SUPERVISOR_ENDPOINT="10.1.0.6"
            REGION_NAME="us-west"
            VPC_NAME="us-west-Default-VPC"
            ZONE_NAME="z-wld-a"
            STORAGE_POLICY="vSAN Default Storage Policy"
            STORAGE_CLASS="vsan-default-storage-policy"
            NS_STORAGE_LIMIT="100000Mi"
            ;;
        2|adv|a)
            LAB_ENV="adv"
            VCFA_ORG="all-apps"
            VCFA_USER="all-apps-admin"
            SUPERVISOR_ENDPOINT="10.1.0.2"
            REGION_NAME="us-west-region"
            VPC_NAME="us-west-region-default-vpc"
            ZONE_NAME="z-wld-a"
            STORAGE_POLICY="cluster-wld01-01a vSAN Storage Policy"
            STORAGE_CLASS="cluster-wld01-01a-vsan-storage-policy"
            NS_STORAGE_LIMIT="102400Mi"
            ;;
        3|9.1|ss|s)
            LAB_ENV="ss"
            VCFA_ORG="Acme-East-A"
            VCFA_USER="acme-east-a"
            SUPERVISOR_ENDPOINT="10.1.8.132"
            REGION_NAME="us-east-a"
            VPC_NAME="default-us-east-a"
            ZONE_NAME="z-wld-a"
            STORAGE_POLICY="vSAN Default Storage Policy"
            STORAGE_CLASS="vsan-default-storage-policy"
            NS_STORAGE_LIMIT="100000Mi"
            ;;
        *)
            echo "❌ Invalid choice. Please choose 'vks', 'adv', or '9.1'."
            return 1
            ;;
    esac
    echo "Running for ${LAB_ENV^^} environment..."
    echo ""
}

# Prompts the user to pick an environment, then calls resolve_environment.
pick_environment() {
    echo "Which lab environment?"
    echo ""
    echo "  1) vks   → VKS Lab          (org: Broadcom,    user: broadcomadmin)"
    echo "  2) adv   → Advanced Lab     (org: all-apps,    user: all-apps-admin)"
    echo "  3) 9.1   → 9.1 Single Site  (org: Acme-East-A, user: acme-east-a)"
    echo ""
    read -p "Enter your choice [vks/adv/9.1]: " LAB_ENV
    echo ""
    resolve_environment
}

# Generates a VCFA API token (initial setup only — call from setup-lab.sh, not ctx2.sh).
# Exports VCF_CLI_VCFA_API_TOKEN and persists it to ~/.zshrc for future sessions.
get_vcfa_token() {
    local script_dir="$1"
    local token_file="$HOME/Desktop/vcfa_api_token.txt"

    VCF_CLI_VCFA_API_TOKEN=$(python3 "$script_dir/vcfa-token.py" "$VCFA_USER" "$LAB_PASS" "$VCFA_ORG" 2>/tmp/vcfa_token_err.txt || true)

    if [ -z "$VCF_CLI_VCFA_API_TOKEN" ]; then
        echo "⚠️ Could not auto-generate token:"
        cat /tmp/vcfa_token_err.txt 2>/dev/null || true
        read -s -p "   Paste your VCFA API Token: " VCF_CLI_VCFA_API_TOKEN
        echo ""
    fi
    rm -f /tmp/vcfa_token_err.txt

    export VCF_CLI_VCFA_API_TOKEN
    echo "$VCF_CLI_VCFA_API_TOKEN" > "$token_file"

    # Persist for future sessions (exec zsh + ctx2.sh runs)
    local zshrc="$HOME/.zshrc"
    if grep -q "VCF_CLI_VCFA_API_TOKEN" "$zshrc" 2>/dev/null; then
        sed -i "s|^export VCF_CLI_VCFA_API_TOKEN=.*|export VCF_CLI_VCFA_API_TOKEN='$VCF_CLI_VCFA_API_TOKEN'|" "$zshrc"
    else
        echo "export VCF_CLI_VCFA_API_TOKEN='$VCF_CLI_VCFA_API_TOKEN'" >> "$zshrc"
    fi
    echo "✅ VCFA token saved and persisted to $zshrc"
}

# Loads an existing VCFA token — does NOT generate one.
# Use this in ctx2.sh. Fails if no token is available.
load_vcfa_token() {
    if [ -z "$VCF_CLI_VCFA_API_TOKEN" ]; then
        local token_file="$HOME/Desktop/vcfa_api_token.txt"
        if [ -f "$token_file" ]; then
            VCF_CLI_VCFA_API_TOKEN=$(cat "$token_file")
            export VCF_CLI_VCFA_API_TOKEN
        else
            echo "❌ No VCFA token found. Run setup-lab.sh first to generate one."
            return 1
        fi
    fi
    echo "-> Using existing VCFA token."
}

# Fetches the VCFA cert chain and (re)creates the vcfa VCF CLI context.
# Requires: VCF_CLI_VCFA_API_TOKEN, VCFA_ORG, VCFA_ENDPOINT, VCFA_CERT_PATH
setup_vcfa_context() {
    echo "Fetching VCFA certificate chain..."
    mkdir -p "$(dirname "$VCFA_CERT_PATH")"
    openssl s_client -showcerts -connect "$VCFA_ENDPOINT:443" </dev/null 2>/dev/null \
        | awk '/BEGIN CERTIFICATE/,/END CERTIFICATE/{print}' > "$VCFA_CERT_PATH"

    echo "Creating VCFA CLI context..."
    vcf context delete vcfa 2>/dev/null || true
    vcf context create vcfa \
      --endpoint "$VCFA_ENDPOINT" \
      --api-token "$VCF_CLI_VCFA_API_TOKEN" \
      --tenant-name "$VCFA_ORG" \
      --ca-certificate "$VCFA_CERT_PATH" 2>/dev/null \
      || echo "VCFA context may already exist. Continuing..."
}

# Finds the namespace context, registers the JWT authenticator, and fetches kubeconfig.
# Requires: CLUSTER_NAME
configure_cluster_context() {
    echo ""
    echo "Configuring VKS cluster context for $CLUSTER_NAME..."

    echo "-> Finding VCFA namespace context..."
    NS_CTX=$(vcf context list -o json 2>/dev/null | jq -r '.[].name' 2>/dev/null | grep -i "e2e-ns" | head -1 || true)

    if [ -z "$NS_CTX" ]; then
        echo "⚠️ Could not auto-detect the namespace context."
        echo "   Available contexts:"
        vcf context list 2>/dev/null || true
        echo ""
        read -p "   Enter the namespace context name (e.g. vcfa:e2e-ns): " NS_CTX
    fi

    echo "-> Switching to namespace context: $NS_CTX"
    yes | vcf context use "$NS_CTX" 2>/dev/null || echo "   (context switch warning — continuing)"

    echo ""
    echo "-> Waiting for VKS cluster to be fully ready before configuring auth..."
    echo "   Checking every 30 seconds for up to 15 minutes..."
    echo ""
    CLUSTER_READY=false
    for i in $(seq 1 30); do
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
        echo "   Re-run ctx2.sh manually once the cluster is up."
        return 1
    fi

    echo "-> Waiting 60s for Pinniped Concierge to stabilize..."
    sleep 60

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
        echo "   Retry manually: vcf cluster register-vcfa-jwt-authenticator $CLUSTER_NAME"
    fi

    echo "-> Fetching kubeconfig for the VKS cluster..."
    mkdir -p ~/.kube
    if ! vcf cluster kubeconfig get "$CLUSTER_NAME"; then
        echo "⚠️ Kubeconfig fetch failed."
        echo "   Run manually: vcf cluster kubeconfig get $CLUSTER_NAME"
    fi

    if [ -f ~/.kube/config ] && grep -q "$CLUSTER_NAME" ~/.kube/config 2>/dev/null; then
        echo "-> Finding cluster context name..."
        CLUSTER_CTX=$(grep "name:.*${CLUSTER_NAME}.*@" ~/.kube/config | awk '{print $2}' | head -1 || true)

        if [ -z "$CLUSTER_CTX" ]; then
            echo "⚠️ Could not auto-detect the cluster context name."
            echo "   Matching entries in kubeconfig:"
            grep "$CLUSTER_NAME" ~/.kube/config || true
            echo ""
            read -p "   Paste the context name (the one with the @ sign): " CLUSTER_CTX
        fi

        echo ""
        echo "  ✅ Cluster context is ready in your kubeconfig."
        echo "     To switch to it, run:  kctx $CLUSTER_CTX"
        echo ""
    else
        echo "⚠️ Kubeconfig does not contain $CLUSTER_NAME yet."
        echo "   The cluster may still be provisioning. Run ctx2.sh when ready."
        echo ""
    fi
}
