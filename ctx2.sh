#!/bin/bash
# Standalone test script for VKS Cluster Context Configuration (Section 11)
# Run this directly to test/debug the cluster context setup without re-running the full script.

set -e
CLUSTER_NAME="e2e-niran-cls01"

echo ""
echo "Configuring VKS cluster context for $CLUSTER_NAME..."

# Recreate the VCFA context so namespace contexts show up in the list
LAB_DIR="$HOME/field-lab"
VCFA_CERT_PATH="$LAB_DIR/vcfa_chain.pem"
TOKEN_FILE="$HOME/Desktop/vcfa_api_token.txt"

# FIX 1: Add "|| true" so a missing file doesn't kill the script!
VCFA_TOKEN=$(cat "$TOKEN_FILE" 2>/dev/null || true)

if [ -z "$VCFA_TOKEN" ]; then
    echo "⚠️ No VCFA token found at $TOKEN_FILE"
    read -s -p "   Paste your VCFA API Token: " VCFA_TOKEN
    echo ""
fi

echo "-> Deleting existing VCFA context..."
vcf context delete vcfa 2>/dev/null || true

echo "-> Fetching VCFA certificate chain..."
openssl s_client -showcerts -connect auto-a.site-a.vcf.lab:443 </dev/null 2>/dev/null | awk '/BEGIN CERTIFICATE/,/END CERTIFICATE/{print}' > "$VCFA_CERT_PATH"

echo "-> Recreating VCFA context..."
# FIX 2: Removed 2>/dev/null so you can actually see if it throws an SSL or Token error
vcf context create vcfa \
  --endpoint auto-a.site-a.vcf.lab \
  --api-token "$VCFA_TOKEN" \
  --tenant-name all-apps \
  --ca-certificate "$VCFA_CERT_PATH" || echo "   Context creation returned a warning. Continuing..."

# We need a namespace-level context (e.g. vcfa:e2e-ns), not the top-level vcfa context.
# Auto-detect the namespace context from the list of available contexts.
echo "-> Finding VCFA namespace context..."
# FIX 3: Add "|| true" so grep failing to find a match doesn't kill the script!
NS_CTX=$(vcf context list -o json 2>/dev/null | jq -r '.[].name' 2>/dev/null | grep -i "e2e-ns" | head -1 || true)

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

echo "-> Registering VCFA JWT authenticator on the cluster..."
echo "   (This can take a minute — waiting up to 2 minutes...)"
if ! timeout 120 bash -c "yes | vcf cluster register-vcfa-jwt-authenticator \"$CLUSTER_NAME\" 2>&1"; then
    echo "⚠️ JWT authenticator registration timed out or failed."
    echo "   You can run this manually later:"
    echo "   vcf cluster register-vcfa-jwt-authenticator $CLUSTER_NAME"
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
    echo "   The cluster may still be provisioning. Run these manually when ready:"
    echo ""
    echo "   vcf context use <namespace-context>"
    echo "   vcf cluster register-vcfa-jwt-authenticator $CLUSTER_NAME"
    echo "   vcf cluster kubeconfig get $CLUSTER_NAME --export-file ~/.kube/config"
    echo "   Then switch with:  kctx <context-name>"
    echo ""
fi

echo ""
echo "✅ Done!"
