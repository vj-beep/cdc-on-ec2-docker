# Docker Build Options for Custom Connect Image

The CDC pipeline requires a custom Connect image (`cdc-on-ec2-connect:8.0.0`) with:
- Debezium SQL Server Source Connector
- Debezium PostgreSQL Source Connector
- Debezium JDBC Sink Connector
- SqlServerCaseRestorer SMT (custom Java plugin)

## Option 1: Automated Build on Node 4 (Recommended for First Deployment)

**Best for:** New deployments, one-time setup

The standard deployment workflow builds the image on Node 4 during Phase 4:

```bash
./scripts/4-build-connect.sh              # Dispatches build to Node 4 via SSM
# Wait 10-15 minutes for build to complete
./scripts/5-start-node.sh connect         # Start Connect services
```

**Pros:**
- Automatic, integrated into standard deployment flow
- All dependencies handled (Maven, Docker daemon, proxy)
- Repeatable across deployments

**Cons:**
- Takes 10-15 minutes during deployment
- Requires Maven + Docker on Node 4
- Network dependencies (Maven Central, Debezium repositories)

## Option 2: Pre-Built Image from Central Registry (Fastest)

**Best for:** Repeatable deployments, CI/CD pipelines

If available, pull a pre-built image from your organization's container registry:

```bash
# If your org maintains a registry (e.g., ECR, Docker Hub):
docker pull mycompany/cdc-on-ec2-connect:8.0.0
docker tag mycompany/cdc-on-ec2-connect:8.0.0 cdc-on-ec2-connect:8.0.0

# Then proceed with standard deployment
./scripts/5-start-node.sh connect
./scripts/6-deploy-connectors.sh
```

**Pros:**
- Instant — no build time
- Consistent across all deployments
- Works offline (image already cached)

**Cons:**
- Requires pre-built image in accessible registry
- Requires authentication if private registry

## Option 3: Manual Local Build on Jumpbox

**Best for:** Development, testing, isolated environments

Build the image locally on the jumpbox, then distribute to all nodes:

```bash
# On jumpbox (must have Docker and Maven)
cd cdc-on-ec2-docker
./scripts/4-build-connect.sh --jumpbox

# Tag for distribution
docker tag cdc-on-ec2-connect:8.0.0 mycompany.azurecr.io/cdc-on-ec2-connect:8.0.0
docker push mycompany.azurecr.io/cdc-on-ec2-connect:8.0.0

# On each node:
docker pull mycompany.azurecr.io/cdc-on-ec2-connect:8.0.0
docker tag mycompany.azurecr.io/cdc-on-ec2-connect:8.0.0 cdc-on-ec2-connect:8.0.0
```

**Pros:**
- Full control over build environment
- Can be optimized and cached locally
- Good for debugging build issues

**Cons:**
- Manual steps required
- Requires Docker + Maven on jumpbox
- Network/proxy configuration needed for Maven

## Build Components Included in Repository

All necessary build artifacts are committed to the repository:

1. **Dockerfile:** `connect/Dockerfile`
   - Based on `confluentinc/cp-server-connect:8.0.0`
   - Installs Debezium connectors and SqlServerCaseRestorer SMT

2. **SMT Source Code:** `connect/smt/src/main/java/...`
   - SqlServerCaseRestorer Java plugin
   - Compiles to JAR via Maven

3. **Debezium Connectors (Pre-Downloaded):** `connect/debezium-libs/`
   - debezium-connector-sqlserver-3.2.6.Final-plugin.tar.gz
   - debezium-connector-postgres-3.2.6.Final-plugin.tar.gz
   - debezium-connector-jdbc-3.2.6.Final-plugin.tar.gz
   - Cached locally to avoid Maven Central rate-limiting during build

4. **JDBC Driver:** `connect/jars/mssql-jdbc-12.4.2.jre11.jar`
   - SQL Server JDBC driver (required, must be downloaded separately)

5. **Docker Compose Overlay:** `docker-compose.connect-build.yml`
   - Build-time compose file for local builds
   - Specifies image name and context

## Network Requirements

### Maven Central Download
- **Endpoints:** repo1.maven.org, central.maven.org
- **Timeout:** ~2-3 minutes for connector downloads
- **Proxy:** If behind corporate proxy, ensure Maven is configured (see `~/.m2/settings.xml`)

### Docker Registry (if pushing to private registry)
- **Endpoint:** Your organization's container registry (ECR, ACR, Docker Hub, etc.)
- **Size:** 2.2 GB for `cdc-on-ec2-connect:8.0.0`
- **Time:** 5-10 minutes over typical network (100 MB/s upload speed assumed)

## Troubleshooting Build Failures

### Issue: "Maven Central 403 Forbidden"
**Cause:** Rate-limiting or access restrictions  
**Fix:** 
1. Pre-downloaded connectors are cached in `connect/debezium-libs/` — build should use these
2. If building on Node 4 without pre-cached connectors, set HTTP proxy:
   ```bash
   export HTTP_PROXY=http://proxy.yourcompany.com:3128
   mvn -f connect/smt/pom.xml clean package
   ```

### Issue: "Docker daemon not running"
**Cause:** Docker service not started on build node  
**Fix:**
1. On Node 4: `sudo systemctl start docker`
2. On jumpbox: `docker ps` to verify daemon is accessible

### Issue: "Out of disk space"
**Cause:** Docker image is 2.2 GB, intermediate layers add more  
**Fix:**
1. Ensure `/data/kafka` or `/var/lib/docker` has at least 10 GB free
2. Clean unused images: `docker image prune -a`

### Issue: "SMT JAR not found in image"
**Cause:** Maven build failed silently  
**Fix:**
1. Check Maven build logs: Look for "BUILD SUCCESS" message
2. Verify `connect/smt/target/kafka-connect-sqlserver-case-restorer-*.jar` exists
3. Check `connect/Dockerfile` references correct JAR name

## Build Artifacts Retained

After building, these artifacts remain:

- **Docker image:** `cdc-on-ec2-connect:8.0.0` (2.2 GB)
- **SMT JAR:** `connect/smt/target/kafka-connect-sqlserver-case-restorer-1.0.0.jar` (8.5 KB)
- **Debezium connectors:** `connect/debezium-libs/*.tar.gz` (37 MB total)

These can be cached for faster rebuilds on subsequent deployments.

## Recommended Workflow for Production

1. **First Deployment (from scratch):**
   ```bash
   ./scripts/4-build-connect.sh          # Builds and caches image on Node 4
   ./scripts/5-start-node.sh connect     # Start services
   ./scripts/6-deploy-connectors.sh      # Deploy CDC connectors
   ```

2. **Subsequent Deployments (reusing cached image):**
   - If Node 4 retained the Docker image from previous deployment, Phase 4 reuses it
   - Alternatively, push image to private registry after first build:
     ```bash
     docker tag cdc-on-ec2-connect:8.0.0 myecr.azurecr.io/cdc-on-ec2-connect:8.0.0
     docker push myecr.azurecr.io/cdc-on-ec2-connect:8.0.0
     ```

3. **In Subsequent Runs:**
   - Pull pre-built image: `docker pull myecr.azurecr.io/cdc-on-ec2-connect:8.0.0`
   - Deployment proceeds instantly to Phase 5

## See Also

- `scripts/4-build-connect.sh` — Automated build orchestration
- `connect/Dockerfile` — Image build specification
- `connect/smt/pom.xml` — Maven POM for SMT compilation
- `connect/SMT-COLUMN-CASE-MAPPING.md` — SMT technical documentation
