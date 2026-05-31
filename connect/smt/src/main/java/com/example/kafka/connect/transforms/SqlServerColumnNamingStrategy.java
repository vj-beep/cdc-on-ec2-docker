package com.example.kafka.connect.transforms;

import io.debezium.connector.jdbc.naming.ColumnNamingStrategy;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import java.sql.Connection;
import java.sql.DriverManager;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.util.HashMap;
import java.util.Locale;
import java.util.Map;

/**
 * Debezium JDBC sink ColumnNamingStrategy that resolves lowercase Aurora field names
 * to their original camelCase SQL Server column names.
 *
 * Problem: Debezium JDBC sink bypasses SMT transformations when building its internal
 * JdbcSinkRecord — it reads the original pre-SMT Kafka record. So SMT-based column
 * renaming never reaches Debezium's column lookup. This strategy hooks directly into
 * the Debezium column resolution path.
 *
 * At startup, queries SQL Server sys.columns to build a lowercase→actual-case map.
 * resolveColumnName("workitemid") → "workItemId"
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

    // lowercase -> actual case for all columns across all tables in the schema
    private final Map<String, String> columnCaseMap = new HashMap<>();

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

        log.info("SqlServerColumnNamingStrategy: loading column names from schema '{}' via {}", schema, jdbcUrl);
        loadColumnMap(jdbcUrl, user, password, schema);
        log.info("SqlServerColumnNamingStrategy: cached {} column name mappings", columnCaseMap.size());
    }

    private void loadColumnMap(String jdbcUrl, String user, String password, String schema) {
        final String sql =
            "SELECT c.name AS column_name " +
            "FROM sys.tables t " +
            "INNER JOIN sys.schemas s ON t.schema_id = s.schema_id " +
            "INNER JOIN sys.columns c ON t.object_id = c.object_id " +
            "WHERE s.name = ? AND t.is_ms_shipped = 0";

        DriverManager.setLoginTimeout(30);
        try (Connection conn = DriverManager.getConnection(jdbcUrl, user, password);
             PreparedStatement ps = conn.prepareStatement(sql)) {

            ps.setString(1, schema);
            try (ResultSet rs = ps.executeQuery()) {
                while (rs.next()) {
                    String actual = rs.getString("column_name");
                    String lower  = actual.toLowerCase(Locale.ROOT);
                    String prev   = columnCaseMap.put(lower, actual);
                    if (prev != null && !prev.equals(actual)) {
                        log.warn("SqlServerColumnNamingStrategy: case collision for '{}': " +
                                 "'{}' overwritten by '{}'", lower, prev, actual);
                    }
                }
            }
        } catch (SQLException e) {
            throw new RuntimeException(
                "SqlServerColumnNamingStrategy: failed to load column metadata from SQL Server: " +
                e.getMessage(), e);
        }
    }

    @Override
    public String resolveColumnName(String fieldName) {
        if (fieldName == null) return fieldName;
        String resolved = columnCaseMap.get(fieldName.toLowerCase(Locale.ROOT));
        if (resolved != null && !resolved.equals(fieldName)) {
            log.debug("SqlServerColumnNamingStrategy: resolved '{}' -> '{}'", fieldName, resolved);
            return resolved;
        }
        return fieldName;
    }
}
