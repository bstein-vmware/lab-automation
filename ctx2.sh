#!/bin/bash
# Standalone script to configure VKS cluster context.
# Run this directly to set up or refresh the cluster context without re-running setup-lab.sh.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=ctx-lib.sh
source "$SCRIPT_DIR/ctx-lib.sh"

LAB_DIR="$HOME/field-lab"
VCFA_CERT_PATH="$LAB_DIR/vcfa_chain.pem"

echo ""
pick_environment
load_vcfa_token
setup_vcfa_context
configure_cluster_context

echo ""
echo "✅ Done!"
