# Pre-downloaded Connector Plugins

These artifacts are bundled in the repo so the Docker build requires **no internet access** — no Maven Central, no Confluent Hub.

## Current Versions

| Artifact | Version | Source |
|---|---|---|
| Debezium SQL Server Source | 3.2.6.Final | Maven Central |
| Debezium PostgreSQL Source | 3.2.6.Final | Maven Central |
| Debezium JDBC Sink | 3.2.6.Final | Maven Central |
| Debezium Scripting | 3.2.6.Final | Maven Central |
| Groovy | 4.0.26 | Maven Central |
| Groovy JSR-223 | 4.0.26 | Maven Central |

## Updating Versions

Download new artifacts from Maven Central and replace the files in this directory:

```bash
VERSION=3.2.6.Final  # change to new version
BASE=https://repo1.maven.org/maven2/io/debezium

curl -fsSL -o debezium-connector-sqlserver-${VERSION}-plugin.tar.gz \
  ${BASE}/debezium-connector-sqlserver/${VERSION}/debezium-connector-sqlserver-${VERSION}-plugin.tar.gz

curl -fsSL -o debezium-connector-postgres-${VERSION}-plugin.tar.gz \
  ${BASE}/debezium-connector-postgres/${VERSION}/debezium-connector-postgres-${VERSION}-plugin.tar.gz

curl -fsSL -o debezium-connector-jdbc-${VERSION}-plugin.tar.gz \
  ${BASE}/debezium-connector-jdbc/${VERSION}/debezium-connector-jdbc-${VERSION}-plugin.tar.gz

curl -fsSL -o debezium-scripting-${VERSION}.jar \
  ${BASE}/debezium-scripting/${VERSION}/debezium-scripting-${VERSION}.jar
```

Then update `DEBEZIUM_VERSION` in `connect/Dockerfile` and rebuild.
