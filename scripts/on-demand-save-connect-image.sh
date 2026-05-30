#!/bin/bash
#
# On-Demand: Save Pre-Built Connect Image for Reuse
#
# After Phase 4 completes, saves the built Docker image to a tar archive
# so it can be reused in subsequent deployments without rebuilding.
#
# Usage:
#   ./scripts/on-demand-save-connect-image.sh               # Save to docker-images/
#   ./scripts/on-demand-save-connect-image.sh --registry    # Push to ECR/ACR/Docker Hub
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"
IMAGES_DIR="$SCRIPT_DIR/docker-images"

if [[ ! -f "$ENV_FILE" ]]; then
    echo "❌ Error: $ENV_FILE not found"
    exit 1
fi

source "$ENV_FILE"

if [[ -z "${CP_VERSION:-}" ]]; then
    echo "❌ Error: CP_VERSION not set in .env"
    exit 1
fi

IMAGE_NAME="cdc-on-ec2-connect:${CP_VERSION}"

# Check if image exists
if ! docker images --quiet "$IMAGE_NAME" | grep -q .; then
    echo "❌ Error: Docker image '$IMAGE_NAME' not found"
    echo "   Run './scripts/4-build-connect.sh' first to build the image"
    exit 1
fi

echo "📦 Processing Connect image: $IMAGE_NAME"
echo ""

# --- Option 1: Save to tar archive ---
if [[ "${1:-}" != "--registry" ]]; then
    echo "Step 1: Saving image to tar archive..."
    mkdir -p "$IMAGES_DIR"

    TAR_FILE="$IMAGES_DIR/cdc-on-ec2-connect-${CP_VERSION}.tar.gz"

    if [[ -f "$TAR_FILE" ]]; then
        echo "⚠️  File already exists: $TAR_FILE"
        read -p "Overwrite? (y/n) " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            echo "Cancelled."
            exit 0
        fi
        rm "$TAR_FILE"
    fi

    echo "Saving image (this may take 2-3 minutes)..."
    docker save "$IMAGE_NAME" | gzip > "$TAR_FILE"

    SIZE_MB=$(du -h "$TAR_FILE" | cut -f1)
    echo "✅ Image saved: $TAR_FILE ($SIZE_MB)"
    echo ""
    echo "To load this image on another system:"
    echo "  gunzip -c $TAR_FILE | docker load"
    echo ""
    exit 0
fi

# --- Option 2: Push to registry ---
if [[ "${1:-}" == "--registry" ]]; then
    echo "Step 1: Preparing for registry push..."

    # Prompt for registry details
    read -p "Registry URL (e.g., myecr.azurecr.io): " REGISTRY_URL
    read -p "Image name (default: cdc-on-ec2-connect): " IMAGE_CUSTOM_NAME
    IMAGE_CUSTOM_NAME="${IMAGE_CUSTOM_NAME:-cdc-on-ec2-connect}"

    if [[ -z "$REGISTRY_URL" ]]; then
        echo "❌ Registry URL required"
        exit 1
    fi

    REMOTE_IMAGE="$REGISTRY_URL/$IMAGE_CUSTOM_NAME:${CP_VERSION}"

    echo ""
    echo "Step 2: Tagging image..."
    docker tag "$IMAGE_NAME" "$REMOTE_IMAGE"
    echo "✅ Tagged: $REMOTE_IMAGE"
    echo ""

    echo "Step 3: Logging in to registry..."
    docker login "$REGISTRY_URL" || {
        echo "❌ Registry login failed"
        exit 1
    }
    echo ""

    echo "Step 4: Pushing image (this may take 5-10 minutes)..."
    docker push "$REMOTE_IMAGE"

    echo ""
    echo "✅ Image pushed: $REMOTE_IMAGE"
    echo ""
    echo "To pull this image on another system:"
    echo "  docker login $REGISTRY_URL"
    echo "  docker pull $REMOTE_IMAGE"
    echo "  docker tag $REMOTE_IMAGE cdc-on-ec2-connect:${CP_VERSION}"
    echo ""
    exit 0
fi

echo "Usage: $0 [--registry]"
echo "  (no args): Save image to tar archive in docker-images/"
echo "  --registry: Push image to container registry (ECR/ACR/Docker Hub)"
exit 1
