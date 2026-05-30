#!/bin/bash
#
# On-Demand: Load Pre-Built Connect Image
#
# Loads a pre-built Connect Docker image from a tar archive or registry,
# skipping the build phase entirely. Useful for subsequent deployments
# or when distributing pre-built images to customers.
#
# Usage (from tar archive):
#   ./scripts/on-demand-load-connect-image.sh docker-images/cdc-on-ec2-connect-8.0.0.tar.gz
#
# Usage (from registry):
#   ./scripts/on-demand-load-connect-image.sh --registry myecr.azurecr.io/cdc-on-ec2-connect:8.0.0
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"

if [[ ! -f "$ENV_FILE" ]]; then
    echo "❌ Error: $ENV_FILE not found"
    exit 1
fi

source "$ENV_FILE"

if [[ -z "${CP_VERSION:-}" ]]; then
    echo "❌ Error: CP_VERSION not set in .env"
    exit 1
fi

if [[ $# -eq 0 ]]; then
    echo "Usage: $0 <tar-file-or-registry-image>"
    echo ""
    echo "Examples:"
    echo "  Load from tar file:"
    echo "    $0 docker-images/cdc-on-ec2-connect-8.0.0.tar.gz"
    echo ""
    echo "  Load from registry:"
    echo "    $0 --registry myecr.azurecr.io/cdc-on-ec2-connect:8.0.0"
    echo ""
    exit 1
fi

# --- Load from tar archive ---
if [[ "$1" != "--registry" ]]; then
    TAR_FILE="$1"

    if [[ ! -f "$TAR_FILE" ]]; then
        echo "❌ Error: File not found: $TAR_FILE"
        exit 1
    fi

    echo "📦 Loading Connect image from tar archive..."
    echo "   File: $TAR_FILE"
    echo "   Size: $(du -h "$TAR_FILE" | cut -f1)"
    echo ""
    echo "⏳ Loading (this may take 2-3 minutes)..."

    if gunzip -c "$TAR_FILE" | docker load; then
        echo ""
        echo "✅ Image loaded successfully"
        docker images | grep "cdc-on-ec2-connect"
        echo ""
        echo "Next: ./scripts/5-start-node.sh connect"
        exit 0
    else
        echo ""
        echo "❌ Failed to load image from tar archive"
        exit 1
    fi
fi

# --- Load from registry ---
if [[ "$1" == "--registry" ]]; then
    if [[ $# -lt 2 ]]; then
        echo "❌ Error: Registry image URL required"
        echo "   Usage: $0 --registry <registry-url>/<image>:<tag>"
        exit 1
    fi

    REGISTRY_IMAGE="$2"

    echo "📦 Loading Connect image from registry..."
    echo "   Image: $REGISTRY_IMAGE"
    echo ""

    # Login to registry (prompt for credentials)
    REGISTRY_HOST=$(echo "$REGISTRY_IMAGE" | cut -d/ -f1)
    echo "Step 1: Logging in to registry ($REGISTRY_HOST)..."
    docker login "$REGISTRY_HOST" || {
        echo "❌ Registry login failed"
        exit 1
    }
    echo ""

    # Pull image
    echo "Step 2: Pulling image (this may take 5-10 minutes)..."
    if docker pull "$REGISTRY_IMAGE"; then
        echo ""
        echo "Step 3: Tagging as local image..."
        docker tag "$REGISTRY_IMAGE" "cdc-on-ec2-connect:${CP_VERSION}"
        echo ""
        echo "✅ Image loaded successfully"
        docker images | grep "cdc-on-ec2-connect"
        echo ""
        echo "Next: ./scripts/5-start-node.sh connect"
        exit 0
    else
        echo ""
        echo "❌ Failed to pull image from registry"
        exit 1
    fi
fi
