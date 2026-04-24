ARG CP_VERSION=8.0.0
FROM confluentinc/cp-server-connect:${CP_VERSION}

# Debezium 3.x required for CP 8.0.0 (kafka-clients 4.0 removed KafkaConsumer.poll(long)
# which Debezium 2.x relied on — causes NoSuchMethodError at runtime).
ARG DEBEZIUM_HUB_VERSION=3.2.6
ARG DEBEZIUM_VERSION=3.2.6.Final

# Java proxy for confluent-hub install (Java ignores HTTP_PROXY/HTTPS_PROXY env vars).
# JAVA_TOOL_OPTIONS is the officially supported JVM mechanism (JVMTI spec).
# curl uses HTTP_PROXY/HTTPS_PROXY automatically (passed as Docker build args).
ARG PROXY_HOST
ARG PROXY_PORT=8080
ENV JAVA_TOOL_OPTIONS=${PROXY_HOST:+"-Dhttp.proxyHost=${PROXY_HOST} -Dhttp.proxyPort=${PROXY_PORT} -Dhttps.proxyHost=${PROXY_HOST} -Dhttps.proxyPort=${PROXY_PORT}"}

# Install Debezium SQL Server Source connector
RUN confluent-hub install --no-prompt debezium/debezium-connector-sqlserver:${DEBEZIUM_HUB_VERSION}

# Install Debezium PostgreSQL Source connector
RUN confluent-hub install --no-prompt debezium/debezium-connector-postgresql:${DEBEZIUM_HUB_VERSION}

# Install Debezium JDBC Sink connector from Maven Central (not on Confluent Hub).
# Replaces Confluent's kafka-connect-jdbc which is incompatible with CP 8.0.0
# (Utils.mkSet removed in Kafka 3.8). Debezium JDBC Sink handles CDC envelopes
# natively and shares debezium-core classloader for SMTs.
RUN curl -fsSL "https://repo1.maven.org/maven2/io/debezium/debezium-connector-jdbc/${DEBEZIUM_VERSION}/debezium-connector-jdbc-${DEBEZIUM_VERSION}-plugin.tar.gz" \
      -o /tmp/debezium-jdbc.tar.gz && \
    tar -xzf /tmp/debezium-jdbc.tar.gz -C /usr/share/confluent-hub-components/ && \
    rm -f /tmp/debezium-jdbc.tar.gz

# Clear proxy so it does not leak into Connect workers at runtime
ENV JAVA_TOOL_OPTIONS=

# Copy the Microsoft SQL Server JDBC driver (not bundled with Confluent or Debezium).
# Download mssql-jdbc-12.4.2.jre11.jar from Microsoft and place it in connect/jars/ before building.
COPY connect/jars/mssql-jdbc-12.4.2.jre11.jar /usr/share/confluent-hub-components/debezium-connector-jdbc/
