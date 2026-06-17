ARG CP_VERSION=8.0.0
FROM confluentinc/cp-server-connect:${CP_VERSION}

# Debezium 3.x required for CP 8.0.0 (kafka-clients 4.0 removed KafkaConsumer.poll(long)
# which Debezium 2.x relied on — causes NoSuchMethodError at runtime).
ARG DEBEZIUM_VERSION=3.2.6.Final

# Java proxy (JAVA_TOOL_OPTIONS is the JVMTI-spec JVM mechanism).
# curl uses HTTP_PROXY/HTTPS_PROXY automatically (passed as Docker build args).
ARG PROXY_HOST
ARG PROXY_PORT=8080
ARG HTTP_PROXY
ARG HTTPS_PROXY
ARG NO_PROXY
ENV HTTP_PROXY=${HTTP_PROXY} \
    HTTPS_PROXY=${HTTPS_PROXY} \
    NO_PROXY=${NO_PROXY} \
    http_proxy=${HTTP_PROXY} \
    https_proxy=${HTTPS_PROXY} \
    no_proxy=${NO_PROXY} \
    JAVA_TOOL_OPTIONS=${PROXY_HOST:+"-Dhttp.proxyHost=${PROXY_HOST} -Dhttp.proxyPort=${PROXY_PORT} -Dhttps.proxyHost=${PROXY_HOST} -Dhttps.proxyPort=${PROXY_PORT}"}

# Copy pre-downloaded Debezium connectors from build context.
# These are downloaded locally and COPY'd into the build to avoid Maven Central rate-limiting.
COPY connect/debezium-libs/debezium-connector-sqlserver-3.2.6.Final-plugin.tar.gz /tmp/
COPY connect/debezium-libs/debezium-connector-postgres-3.2.6.Final-plugin.tar.gz /tmp/
COPY connect/debezium-libs/debezium-connector-jdbc-3.2.6.Final-plugin.tar.gz /tmp/

RUN tar -xzf /tmp/debezium-connector-sqlserver-3.2.6.Final-plugin.tar.gz -C /usr/share/confluent-hub-components/ && \
    tar -xzf /tmp/debezium-connector-postgres-3.2.6.Final-plugin.tar.gz -C /usr/share/confluent-hub-components/ && \
    tar -xzf /tmp/debezium-connector-jdbc-3.2.6.Final-plugin.tar.gz -C /usr/share/confluent-hub-components/

# Clear proxy so it does not leak into Connect workers at runtime
ENV JAVA_TOOL_OPTIONS= \
    HTTP_PROXY= \
    HTTPS_PROXY= \
    NO_PROXY= \
    http_proxy= \
    https_proxy= \
    no_proxy=

# Copy the Microsoft SQL Server JDBC driver (not bundled with Confluent or Debezium).
# Download mssql-jdbc-12.4.2.jre11.jar from Microsoft and place it in connect/jars/ before building.
COPY connect/jars/mssql-jdbc-12.4.2.jre11.jar /usr/share/confluent-hub-components/debezium-connector-jdbc/

# SqlServerCaseRestorer SMT — pre-built JAR committed alongside mssql-jdbc.
# No Maven build step required; works in proxy/air-gapped environments.
# Copy to both jdbc sink connector dir and main confluent lib for classpath discovery.
COPY connect/jars/kafka-connect-sqlserver-case-restorer-*.jar /usr/share/confluent-hub-components/debezium-connector-jdbc/
COPY connect/jars/kafka-connect-sqlserver-case-restorer-*.jar /usr/share/java/

# StripNullBytes SMT — pre-built JAR for stripping chr(0) null bytes from records.
# Copy to both jdbc sink connector dir and main confluent lib for classpath discovery.
COPY connect/jars/strip-null-bytes-smt.jar /usr/share/confluent-hub-components/debezium-connector-jdbc/
COPY connect/jars/strip-null-bytes-smt.jar /usr/share/java/
