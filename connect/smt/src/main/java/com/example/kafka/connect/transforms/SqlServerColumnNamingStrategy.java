package com.example.kafka.connect.transforms;

import io.debezium.connector.jdbc.naming.ColumnNamingStrategy;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import java.util.Locale;
import java.util.Map;

/**
 * Debezium JDBC sink ColumnNamingStrategy that resolves lowercase Aurora field names
 * to their original camelCase SQL Server column names.
 *
 * Problem: Debezium JDBC sink bypasses SMT transformations when building its internal
 * JdbcSinkRecord — it reads the original pre-SMT Kafka record's schema metadata
 * (__debezium.source.column.name), which always contains Aurora's lowercase column name.
 * So SMT-based column renaming never reaches Debezium's column lookup. This strategy
 * hooks directly into the Debezium column resolution path.
 *
 * Uses SqlServerSchemaCache so metadata is shared with SqlServerCaseRestorer —
 * only one JDBC call is made at startup regardless of which component initialises first.
 * On a cache miss (new column added after startup), reloadOnMiss() re-queries SQL Server
 * once per 60 seconds to handle schema evolution without a connector restart.
 *
 * Config (set on the JDBC sink connector):
 *   column.naming.strategy=com.example.kafka.connect.transforms.SqlServerColumnNamingStrategy
 *   column.naming.strategy.jdbc.url=jdbc:sqlserver://host:1433;databaseName=mydb;encrypt=false
 *   column.naming.strategy.jdbc.user=sa
 *   column.naming.strategy.jdbc.password=secret
 *   column.naming.strategy.table.schema=dbo
 */
public class SqlServerColumnNamingStrategy implements ColumnNamingStrategy {

    private static final Logger log = LoggerFactory.getLogger(SqlServerColumnNamingStrategy.class);

    static final String JDBC_URL_KEY  = "column.naming.strategy.jdbc.url";
    static final String JDBC_USER_KEY = "column.naming.strategy.jdbc.user";
    static final String JDBC_PASS_KEY = "column.naming.strategy.jdbc.password";
    static final String SCHEMA_KEY    = "column.naming.strategy.table.schema";

    // Package-private so tests can suppress reload-on-miss
    SqlServerSchemaCache.Entry cacheEntry;

    @Override
    public void configure(Map<String, String> props) {
        String jdbcUrl  = props.get(JDBC_URL_KEY);
        String user     = props.get(JDBC_USER_KEY);
        String password = props.get(JDBC_PASS_KEY);
        String schema   = props.getOrDefault(SCHEMA_KEY, "dbo");

        if (jdbcUrl == null || user == null || password == null) {
            log.warn("SqlServerColumnNamingStrategy: missing JDBC config — column case mapping disabled. " +
                     "Set {}, {}, {}", JDBC_URL_KEY, JDBC_USER_KEY, JDBC_PASS_KEY);
            return;
        }

        cacheEntry = SqlServerSchemaCache.get(jdbcUrl, user, password, schema);
        log.info("SqlServerColumnNamingStrategy: using shared schema cache ({} columns) for schema '{}' via {}",
                 cacheEntry.flatColumnMap.size(), schema, jdbcUrl);
    }

    @Override
    public String resolveColumnName(String fieldName) {
        if (fieldName == null || cacheEntry == null) return fieldName;

        String lower    = fieldName.toLowerCase(Locale.ROOT);
        String resolved = cacheEntry.flatColumnMap.get(lower);

        if (resolved == null && cacheEntry.reloadOnMiss(fieldName)) {
            resolved = cacheEntry.flatColumnMap.get(lower);
        }

        if (resolved != null && !resolved.equals(fieldName)) {
            log.debug("SqlServerColumnNamingStrategy: resolved '{}' -> '{}'", fieldName, resolved);
            return resolved;
        }
        return fieldName;
    }
}
