ARG CP_VERSION=8.0.0

# Build stage: compile the StripNullBytes SMT jar
FROM maven:3.9-eclipse-temurin-11 AS smt-builder
ARG HTTP_PROXY
ARG HTTPS_PROXY
ARG NO_PROXY
ENV HTTP_PROXY=${HTTP_PROXY} HTTPS_PROXY=${HTTPS_PROXY} NO_PROXY=${NO_PROXY} \
    http_proxy=${HTTP_PROXY} https_proxy=${HTTPS_PROXY} no_proxy=${NO_PROXY}
COPY connect/smt /build
WORKDIR /build
RUN mvn -B -q package -DskipTests

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

# All three Debezium connectors installed from Maven Central.
# Confluent Hub lags behind Maven releases — 3.2.6 available on Maven but not Hub.
RUN curl -fsSL "https://repo1.maven.org/maven2/io/debezium/debezium-connector-sqlserver/${DEBEZIUM_VERSION}/debezium-connector-sqlserver-${DEBEZIUM_VERSION}-plugin.tar.gz" \
      -o /tmp/debezium-sqlserver.tar.gz && \
    tar -xzf /tmp/debezium-sqlserver.tar.gz -C /usr/share/confluent-hub-components/ && \
    rm -f /tmp/debezium-sqlserver.tar.gz

RUN curl -fsSL "https://repo1.maven.org/maven2/io/debezium/debezium-connector-postgres/${DEBEZIUM_VERSION}/debezium-connector-postgres-${DEBEZIUM_VERSION}-plugin.tar.gz" \
      -o /tmp/debezium-postgres.tar.gz && \
    tar -xzf /tmp/debezium-postgres.tar.gz -C /usr/share/confluent-hub-components/ && \
    rm -f /tmp/debezium-postgres.tar.gz

RUN curl -fsSL "https://repo1.maven.org/maven2/io/debezium/debezium-connector-jdbc/${DEBEZIUM_VERSION}/debezium-connector-jdbc-${DEBEZIUM_VERSION}-plugin.tar.gz" \
      -o /tmp/debezium-jdbc.tar.gz && \
    tar -xzf /tmp/debezium-jdbc.tar.gz -C /usr/share/confluent-hub-components/ && \
    rm -f /tmp/debezium-jdbc.tar.gz

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

# Copy the custom StripNullBytes SMT jar into the JDBC sink connector plugin dir
COPY --from=smt-builder /build/target/strip-null-bytes-smt.jar /usr/share/confluent-hub-components/debezium-connector-jdbc/
