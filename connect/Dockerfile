ARG CP_VERSION=8.0.0
FROM confluentinc/cp-server-connect:${CP_VERSION}

# ============================================================
# All connector plugins and dependencies are pre-downloaded in
# connect/plugins/ — no internet required during build.
#
# To update versions, download new artifacts into connect/plugins/
# and update the filenames below. See connect/plugins/README.md.
# ============================================================

ARG DEBEZIUM_VERSION=3.2.6.Final

# --- Debezium SQL Server Source connector ---
COPY connect/plugins/debezium-connector-sqlserver-${DEBEZIUM_VERSION}-plugin.tar.gz /tmp/
RUN tar -xzf /tmp/debezium-connector-sqlserver-${DEBEZIUM_VERSION}-plugin.tar.gz \
      -C /usr/share/confluent-hub-components/ && \
    rm -f /tmp/debezium-connector-sqlserver-${DEBEZIUM_VERSION}-plugin.tar.gz

# --- Debezium PostgreSQL Source connector ---
COPY connect/plugins/debezium-connector-postgres-${DEBEZIUM_VERSION}-plugin.tar.gz /tmp/
RUN tar -xzf /tmp/debezium-connector-postgres-${DEBEZIUM_VERSION}-plugin.tar.gz \
      -C /usr/share/confluent-hub-components/ && \
    rm -f /tmp/debezium-connector-postgres-${DEBEZIUM_VERSION}-plugin.tar.gz

# --- Debezium JDBC Sink connector ---
COPY connect/plugins/debezium-connector-jdbc-${DEBEZIUM_VERSION}-plugin.tar.gz /tmp/
RUN tar -xzf /tmp/debezium-connector-jdbc-${DEBEZIUM_VERSION}-plugin.tar.gz \
      -C /usr/share/confluent-hub-components/ && \
    rm -f /tmp/debezium-connector-jdbc-${DEBEZIUM_VERSION}-plugin.tar.gz

# --- Debezium scripting support (Groovy-based Filter SMT for loop prevention) ---
# Kafka Connect uses per-plugin classloaders — scripting JARs must be copied
# into every connector that uses the Filter SMT.
COPY connect/plugins/debezium-scripting-${DEBEZIUM_VERSION}.jar /tmp/
COPY connect/plugins/groovy-4.0.26.jar /tmp/
COPY connect/plugins/groovy-jsr223-4.0.26.jar /tmp/
RUN for dir in \
      /usr/share/confluent-hub-components/debezium-connector-sqlserver \
      /usr/share/confluent-hub-components/debezium-connector-postgres \
      /usr/share/confluent-hub-components/debezium-connector-jdbc; do \
        cp /tmp/debezium-scripting-${DEBEZIUM_VERSION}.jar \
           /tmp/groovy-4.0.26.jar \
           /tmp/groovy-jsr223-4.0.26.jar \
           "$dir/"; \
    done && \
    rm -f /tmp/debezium-scripting-*.jar /tmp/groovy*.jar

# --- Microsoft SQL Server JDBC driver (required for JDBC Sink to write to SQL Server) ---
COPY connect/jars/mssql-jdbc-12.4.2.jre11.jar /usr/share/confluent-hub-components/debezium-connector-jdbc/
