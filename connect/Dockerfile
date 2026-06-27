ARG CP_VERSION=8.0.0
FROM confluentinc/cp-server-connect:${CP_VERSION}

# Debezium 3.x required for CP 8.0.0 (kafka-clients 4.0 removed KafkaConsumer.poll(long)
# which Debezium 2.x relied on — causes NoSuchMethodError at runtime).
# Confluent Hub version strings drop the .Final suffix used in Maven Central artifacts.
ARG DEBEZIUM_VERSION=3.2.6
# Confluent JDBC sink replaces the community Debezium JDBC sink for enterprise support coverage.
ARG CONFLUENT_JDBC_VERSION=10.9.5

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

# Install connectors from Confluent Hub.
# Sources use the Debezium namespace but are Confluent-distributed and enterprise-support-covered.
# Sink is the Confluent-authored JDBC connector (io.confluent.connect.jdbc.JdbcSinkConnector).
RUN confluent-hub install --no-prompt debezium/debezium-connector-sqlserver:${DEBEZIUM_VERSION} && \
    confluent-hub install --no-prompt debezium/debezium-connector-postgresql:${DEBEZIUM_VERSION} && \
    confluent-hub install --no-prompt confluentinc/kafka-connect-jdbc:${CONFLUENT_JDBC_VERSION}

# Clear proxy so it does not leak into Connect workers at runtime
ENV JAVA_TOOL_OPTIONS= \
    HTTP_PROXY= \
    HTTPS_PROXY= \
    NO_PROXY= \
    http_proxy= \
    https_proxy= \
    no_proxy=

# Copy JDBC drivers into the Confluent JDBC connector plugin directory.
# Neither driver is bundled with the connector — both must be present for the dialect classes to load.
COPY connect/jars/mssql-jdbc-12.4.2.jre11.jar /usr/share/confluent-hub-components/confluentinc-kafka-connect-jdbc/
COPY connect/jars/postgresql-42.7.3.jar /usr/share/confluent-hub-components/confluentinc-kafka-connect-jdbc/

# SqlServerCaseRestorer SMT — pre-built JAR committed alongside mssql-jdbc.
# No Maven build step required; works in proxy/air-gapped environments.
# /usr/share/java/ is on the Connect worker classpath — sufficient for SMT discovery.
COPY connect/jars/kafka-connect-sqlserver-case-restorer-*.jar /usr/share/java/

# StripNullBytes SMT — pre-built thin JAR (no bundled deps) for stripping chr(0) from records.
COPY connect/jars/strip-null-bytes-smt.jar /usr/share/java/
