# Docker Image Deployment Guide

## Quick Start

The CDC deployment requires a custom Connect image with Debezium connectors and the SqlServerCaseRestorer SMT.

### Option 1: First Deployment (Recommended)

Use the standard automated build:

```bash
./scripts/4-build-connect.sh              # Builds on Node 4 (5-10 min)
./scripts/5-start-node.sh connect         # Start services
./scripts/6-deploy-connectors.sh          # Deploy CDC connectors
```

### Option 2: Subsequent Deployments (Faster)

Reuse the image from your first deployment:

```bash
# If Node 4 retained the Docker image from previous deployment,
# Phase 4 will reuse it (instant).
# Or explicitly load a saved image:
./scripts/on-demand-load-connect-image.sh docker-images/cdc-on-ec2-connect-8.0.0.tar.gz
./scripts/5-start-node.sh connect
./scripts/6-deploy-connectors.sh
```

---

## Understanding Docker Images in This Deployment

### What is the Custom Connect Image?

The `cdc-on-ec2-connect:8.0.0` image is based on Confluent's Connect but adds:

1. **Debezium Connectors** (3 plugins, 37 MB total)
   - debezium-connector-sqlserver (SQL Server CDC source)
   - debezium-connector-postgres (Aurora CDC source)
   - debezium-connector-jdbc (JDBC sink for both SQL Server and Aurora)

2. **SqlServerCaseRestorer SMT** (8.5 KB)
   - Custom Java plugin for column name case mapping
   - Queries SQL Server metadata at startup
   - Restores mixed-case table/column names on reverse-path CDC

3. **SQL Server JDBC Driver** (6 MB)
   - mssql-jdbc-12.4.2.jre11.jar (required for SQL Server sink)

**Total Size:** ~2.2 GB (compressed from base image: 2.55 GB)

### Why Not Use Pre-Built Public Images?

Official Confluent Connect images don't include Debezium connectors or the SqlServerCaseRestorer SMT. This custom image is necessary because:

1. **Debezium plugins** are not pre-installed — must be added during build
2. **SqlServerCaseRestorer** is a custom plugin specific to bi-directional CDC case mapping
3. **Combining into one image** simplifies deployment (no runtime plugin installation)

---

## Build Options

### Option 1: Automatic Build on Node 4 (Standard)

**When to use:** First deployment, no pre-built images available

**Command:**
```bash
./scripts/4-build-connect.sh              # Auto-detects DISPATCH_MODE (SSM or SSH)
```

**What happens:**
1. Phase 4 compiles the SqlServerCaseRestorer SMT JAR (Maven)
2. Downloads Debezium connectors (or uses cached versions)
3. Builds Docker image using `connect/Dockerfile`
4. Image stored locally on Node 4

**Time:** 5-10 minutes  
**Prerequisites:** Node 4 has Maven, Docker daemon, network access

**Pros:**
- Integrated into standard deployment workflow
- Handles proxy configuration automatically
- Single command

**Cons:**
- Takes 10+ minutes per deployment
- Requires Maven on Node 4

### Option 2: Load from Saved Tar Archive (Offline-Friendly)

**When to use:** Repeatable deployments, distributing to multiple customers, offline environments

**Step 1: After first build, save the image**
```bash
./scripts/on-demand-save-connect-image.sh
# Output: docker-images/cdc-on-ec2-connect-8.0.0.tar.gz (2.2 GB)
```

**Step 2: On subsequent deployments, load the image**
```bash
./scripts/on-demand-load-connect-image.sh docker-images/cdc-on-ec2-connect-8.0.0.tar.gz
# Skips Phase 4 build entirely
```

**Time:** 2-3 minutes to load from tar  
**File Size:** 2.2 GB (can be compressed further with `tar -J` for ~1.5 GB)

**Pros:**
- Instant — no build time
- Portable — can be copied to other machines
- Reproducible — same image always

**Cons:**
- Large file (2.2 GB) to manage
- Initial 2-3 minute load time
- Requires tar utilities

### Option 3: Push to Container Registry (Best for Teams)

**When to use:** Multiple deployments, team collaboration, CI/CD pipelines

**Step 1: After first build, push to registry**
```bash
./scripts/on-demand-save-connect-image.sh --registry
# Prompts for registry URL (e.g., myecr.azurecr.io)
# Logs in, tags, and pushes image
```

**Step 2: On subsequent deployments, pull the image**
```bash
./scripts/on-demand-load-connect-image.sh --registry myecr.azurecr.io/cdc-on-ec2-connect:8.0.0
# Logs in, pulls, and tags as local image
```

**Time:** 5-10 minutes initial push, 5-10 minutes pull  
**Prerequisites:** Access to container registry (ECR, ACR, Docker Hub, Quay, etc.)

**Pros:**
- Highly available — centralized repository
- Version control — tag different builds
- Team access — multiple users can pull
- CI/CD friendly — automated pipeline integration

**Cons:**
- Requires registry setup and credentials
- Network bandwidth for push/pull
- Registry storage costs (2.2 GB per version)

### Option 4: Manual Build on Jumpbox (Development)

**When to use:** Testing, debugging, development environments

**Step 1: Build on jumpbox**
```bash
# On jumpbox (must have Docker + Maven):
cd cdc-on-ec2-docker
./scripts/4-build-connect.sh --jumpbox
```

**Step 2: Push to registry or save to tar**
```bash
# Either push to registry:
./scripts/on-demand-save-connect-image.sh --registry

# Or save locally:
./scripts/on-demand-save-connect-image.sh

# Then distribute to nodes
```

**Time:** 5-10 minutes build + 5-10 minutes distribution  
**Prerequisites:** Jumpbox has Docker + Maven

**Pros:**
- Full control over build process
- Can inspect/debug build
- Good for customization

**Cons:**
- Manual distribution to nodes required
- Jumpbox needs Docker/Maven installed

---

## Recommended Workflow

### For Small Deployments (1-2 systems)

```
1. First deployment:
   ./scripts/4-build-connect.sh              # Build on Node 4
   ./scripts/5-start-node.sh connect
   ./scripts/6-deploy-connectors.sh

2. Subsequent deployments:
   ./scripts/5-start-node.sh connect         # Reuse cached image
   ./scripts/6-deploy-connectors.sh
```

**No extra steps needed** — Docker caches the image on Node 4.

### For Medium Deployments (3-10 systems)

```
1. First deployment (System A):
   ./scripts/4-build-connect.sh              # Build on Node 4
   ./scripts/on-demand-save-connect-image.sh # Save to tar (optional)

2. Subsequent deployments (Systems B-C):
   ./scripts/on-demand-load-connect-image.sh docker-images/cdc-on-ec2-connect-8.0.0.tar.gz
   ./scripts/5-start-node.sh connect
   ./scripts/6-deploy-connectors.sh
```

**Benefit:** Skip Maven/Docker build time on repeated systems.

### For Large Deployments (10+ systems) or CI/CD

```
1. First deployment or in CI/CD pipeline:
   ./scripts/4-build-connect.sh              # Build on Node 4 or jumpbox
   ./scripts/on-demand-save-connect-image.sh --registry  # Push to ECR/ACR

2. All subsequent deployments:
   ./scripts/on-demand-load-connect-image.sh --registry <registry-url>
   ./scripts/5-start-node.sh connect
   ./scripts/6-deploy-connectors.sh
```

**Benefit:** Centralized image repository, fast pulls, version control.

---

## Pre-Cached Artifacts in Repository

To avoid Maven Central rate-limiting during builds, the repository includes:

**`connect/debezium-libs/`** (37 MB total, Git-tracked)
- debezium-connector-sqlserver-3.2.6.Final-plugin.tar.gz
- debezium-connector-postgres-3.2.6.Final-plugin.tar.gz
- debezium-connector-jdbc-3.2.6.Final-plugin.tar.gz

These are downloaded once and cached, so the build doesn't need internet access to Maven Central for these specific artifacts.

**`connect/jars/`** (6 MB total, Git-tracked)
- mssql-jdbc-12.4.2.jre11.jar

This SQL Server JDBC driver is required and included in the build.

---

## Troubleshooting

### Build Takes Too Long (>20 minutes)

**Cause:** Maven downloading dependencies or network latency  
**Fix:**
1. Check node network: `curl -w "time_total: %{time_total}\n" https://google.com`
2. Verify proxy settings: `echo $HTTP_PROXY $HTTPS_PROXY`
3. Check Maven cache: `du -sh ~/.m2/repository/` (should be >1 GB after first build)

**Next time:** Use `on-demand-save-connect-image.sh` to save the image after build completes.

### "Image not found" on Node 4

**Cause:** Build failed or image didn't load  
**Fix:**
1. Check if Node 4 has the image: `docker images | grep cdc-on-ec2-connect`
2. If not present, retry build: `./scripts/4-build-connect.sh`
3. If build fails repeatedly, check logs: See "Build Failures" in `DOCKER-BUILD-OPTIONS.md`

### Registry Push Failed

**Cause:** Authentication error or network issue  
**Fix:**
1. Manual login test: `docker login <registry-url>`
2. Check credentials and permissions
3. Verify network access to registry
4. Try saving to tar first: `./scripts/on-demand-save-connect-image.sh`

### Docker Image Size Too Large

**Cause:** Limited disk space on Node 4 or local machine  
**Fix:**
1. Check available disk: `df -h /data/kafka` or `df -h /var/lib/docker`
2. Clean unused images: `docker image prune -a --filter "until=720h"`
3. If space still an issue, use registry push instead of tar file

---

## Image Version Management

The image is tagged as `cdc-on-ec2-connect:${CP_VERSION}` (default: `8.0.0`).

If you need multiple versions:

```bash
# Tag image with custom version
docker tag cdc-on-ec2-connect:8.0.0 cdc-on-ec2-connect:8.0.0-with-masking
docker tag cdc-on-ec2-connect:8.0.0 myregistry.azurecr.io/cdc-on-ec2-connect:v1.0.0

# Push specific version
docker push myregistry.azurecr.io/cdc-on-ec2-connect:v1.0.0

# Pull specific version
docker pull myregistry.azurecr.io/cdc-on-ec2-connect:v1.0.0
docker tag myregistry.azurecr.io/cdc-on-ec2-connect:v1.0.0 cdc-on-ec2-connect:8.0.0
```

---

## Summary

| Scenario | Command | Time | Best For |
|----------|---------|------|----------|
| **First deploy** | `./scripts/4-build-connect.sh` | 5-10 min | Standard, new systems |
| **Repeat deploy** | None (cached on Node 4) | 0 min | Node 4 has image cached |
| **Save for reuse** | `./scripts/on-demand-save-connect-image.sh` | 2-3 min | Offline, portable |
| **Load from tar** | `./scripts/on-demand-load-connect-image.sh <tar>` | 2-3 min | Subsequent deploys |
| **Push to registry** | `./scripts/on-demand-save-connect-image.sh --registry` | 5-10 min | Teams, CI/CD |
| **Pull from registry** | `./scripts/on-demand-load-connect-image.sh --registry <url>` | 5-10 min | Subsequent deploys |

**Default recommendation:** Use Option 1 (automatic build) for first deployment, then save the image using Option 2 or 3 for faster subsequent deployments.
