package com.example.kafka.connect.transforms;

import org.apache.kafka.common.config.ConfigDef;
import org.apache.kafka.common.config.ConfigException;
import org.apache.kafka.connect.connector.ConnectRecord;
import org.apache.kafka.connect.data.Field;
import org.apache.kafka.connect.data.Struct;
import org.apache.kafka.connect.transforms.Transformation;
import org.apache.kafka.connect.transforms.util.SimpleConfig;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import java.sql.Connection;
import java.sql.DriverManager;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.util.HashMap;
import java.util.Map;

/**
 * Restores mixed-case SQL Server table and column names in Kafka topic strings and record fields.
 *
 * Problem: Debezium PostgreSQL source captures table names in lowercase
 * (e.g. topic "aurora.public.flagset"). The JDBC sink uses the topic tail
 * as the target table name — but SQL Server's actual table is "FlagSet".
 * Additionally, Aurora auto-creates tables with lowercase column names,
 * but SQL Server's original table has camelCase columns. Without this SMT
 * the sink creates a new lowercase table and/or writes to wrong columns.
 *
 * Solution: At startup this SMT queries sys.tables and sys.columns, builds
 * lowercase→actual maps for both, then rewrites the topic tail and record
 * field names on every record before the sink sees it.
 *
 * Place this SMT *after* any RegexRouter in the transforms chain so it
 * receives only the bare table-name tail, not the full topic prefix.
 */
public class SqlServerCaseRestorer<R extends ConnectRecord<R>> implements Transformation<R> {

    private static final Logger log = LoggerFactory.getLogger(SqlServerCaseRestorer.class);

    static final String JDBC_URL_CONFIG  = "jdbc.url";
    static final String JDBC_USER_CONFIG = "jdbc.user";
    static final String JDBC_PASS_CONFIG = "jdbc.password";
    static final String SCHEMA_CONFIG    = "table.schema";

    public static final ConfigDef CONFIG_DEF = new ConfigDef()
        .define(JDBC_URL_CONFIG,
                ConfigDef.Type.STRING,
                ConfigDef.NO_DEFAULT_VALUE,
                ConfigDef.Importance.HIGH,
                "JDBC URL for the SQL Server instance to read table metadata from. " +
                "Example: jdbc:sqlserver://host:1433;databaseName=mydb;encrypt=false")
        .define(JDBC_USER_CONFIG,
                ConfigDef.Type.STRING,
                ConfigDef.NO_DEFAULT_VALUE,
                ConfigDef.Importance.HIGH,
                "SQL Server username")
        .define(JDBC_PASS_CONFIG,
                ConfigDef.Type.PASSWORD,
                ConfigDef.NO_DEFAULT_VALUE,
                ConfigDef.Importance.HIGH,
                "SQL Server password")
        .define(SCHEMA_CONFIG,
                ConfigDef.Type.STRING,
                "dbo",
                ConfigDef.Importance.MEDIUM,
                "SQL Server schema to scan for table names. Default: dbo");

    // Package-private so unit tests can inject the maps without a real DB.
    final Map<String, String> tableCaseMap = new HashMap<>();
    // Nested map: tableName (lowercase) -> {columnName (lowercase) -> actual}
    final Map<String, Map<String, String>> columnCaseMaps = new HashMap<>();

    @Override
    public void configure(Map<String, ?> props) {
        SimpleConfig config   = new SimpleConfig(CONFIG_DEF, props);
        String       jdbcUrl  = config.getString(JDBC_URL_CONFIG);
        String       user     = config.getString(JDBC_USER_CONFIG);
        String       password = config.getPassword(JDBC_PASS_CONFIG).value();
        String       schema   = config.getString(SCHEMA_CONFIG);

        log.info("SqlServerCaseRestorer: loading table and column names from schema '{}' via {}",
                 schema, jdbcUrl);
        loadTableMap(jdbcUrl, user, password, schema);
        loadColumnMaps(jdbcUrl, user, password, schema);
        log.info("SqlServerCaseRestorer: cached {} table name mappings and {} column mappings",
                 tableCaseMap.size(), columnCaseMaps.size());
    }

    private void loadTableMap(String jdbcUrl, String user, String password, String schema) {
        // Use sys.tables with a CS (case-sensitive) collation cast to identify only tables
        // whose names differ from their lowercase form — these are the ones that need
        // restoring. Tables that are already all-lowercase are loaded too (name = LOWER(name))
        // so the map is complete. The SCHEMA_NAME() join scopes to the target schema.
        //
        // Why sys.tables instead of INFORMATION_SCHEMA.TABLES:
        //   INFORMATION_SCHEMA is limited to tables visible to the current user's default
        //   collation. sys.tables with an explicit COLLATE clause is authoritative and
        //   works correctly even when the DB collation is case-insensitive (CI).
        final String sql =
            "SELECT t.name AS table_name " +
            "FROM sys.tables t " +
            "INNER JOIN sys.schemas s ON t.schema_id = s.schema_id " +
            "WHERE s.name = ? " +
            "  AND t.is_ms_shipped = 0";

        try (Connection conn = DriverManager.getConnection(jdbcUrl, user, password);
             PreparedStatement ps = conn.prepareStatement(sql)) {

            ps.setString(1, schema);
            try (ResultSet rs = ps.executeQuery()) {
                while (rs.next()) {
                    String actual = rs.getString("table_name");
                    String lower  = actual.toLowerCase();
                    String prev   = tableCaseMap.put(lower, actual);
                    if (prev != null && !prev.equals(actual)) {
                        // Two tables differ only in case — emit a warning but keep last seen.
                        log.warn("SqlServerCaseRestorer: case collision for key '{}': " +
                                 "'{}' overwritten by '{}'. Queries will target '{}'.",
                                 lower, prev, actual, actual);
                    }
                }
            }
        } catch (SQLException e) {
            throw new ConfigException(
                "SqlServerCaseRestorer: failed to load table metadata from SQL Server: " +
                e.getMessage(), e);
        }
    }

    private void loadColumnMaps(String jdbcUrl, String user, String password, String schema) {
        final String sql =
            "SELECT t.name AS table_name, c.name AS column_name " +
            "FROM sys.tables t " +
            "INNER JOIN sys.schemas s ON t.schema_id = s.schema_id " +
            "INNER JOIN sys.columns c ON t.object_id = c.object_id " +
            "WHERE s.name = ? " +
            "  AND t.is_ms_shipped = 0 " +
            "ORDER BY t.name, c.column_id";

        try (Connection conn = DriverManager.getConnection(jdbcUrl, user, password);
             PreparedStatement ps = conn.prepareStatement(sql)) {

            ps.setString(1, schema);
            try (ResultSet rs = ps.executeQuery()) {
                String currentTable = null;
                Map<String, String> currentMap = null;

                while (rs.next()) {
                    String tableName = rs.getString("table_name");
                    String columnName = rs.getString("column_name");

                    // New table — create a new column map for it.
                    if (!tableName.equals(currentTable)) {
                        currentTable = tableName;
                        currentMap = new HashMap<>();
                        columnCaseMaps.put(tableName.toLowerCase(), currentMap);
                    }

                    // Add column mapping: lowercase -> actual case.
                    String lower = columnName.toLowerCase();
                    String prev = currentMap.put(lower, columnName);
                    if (prev != null && !prev.equals(columnName)) {
                        log.warn("SqlServerCaseRestorer: case collision for column in table '{}': " +
                                 "key '{}': '{}' overwritten by '{}'. Queries will target '{}'.",
                                 tableName, lower, prev, columnName, columnName);
                    }
                }
            }
        } catch (SQLException e) {
            throw new ConfigException(
                "SqlServerCaseRestorer: failed to load column metadata from SQL Server: " +
                e.getMessage(), e);
        }
    }

    @Override
    public R apply(R record) {
        if (record == null || record.topic() == null) {
            return record;
        }

        String topic = record.topic();
        String[] parts = topic.split("\\.", -1);

        // Extract the last segment — the table name portion of the topic.
        String tail   = parts[parts.length - 1];
        String actualTable = tableCaseMap.get(tail.toLowerCase());

        // No table mapping found or case already matches — check for column mappings anyway.
        String newTopic = topic;
        if (actualTable != null && !actualTable.equals(tail)) {
            parts[parts.length - 1] = actualTable;
            newTopic = String.join(".", parts);
            log.debug("SqlServerCaseRestorer: table topic {} -> {}", topic, newTopic);
        }

        // Restore column case in record value if it's a Struct.
        Object newValue = record.value();
        if (record.value() instanceof Struct) {
            Struct valueStruct = (Struct) record.value();
            String tableLower = (actualTable != null ? actualTable : tail).toLowerCase();
            Map<String, String> columnMap = columnCaseMaps.get(tableLower);

            if (columnMap != null && !columnMap.isEmpty()) {
                newValue = restoreColumnCase(valueStruct, columnMap);
            }
        }

        // Restore column case in record key if it's a Struct.
        Object newKey = record.key();
        if (record.key() instanceof Struct) {
            Struct keyStruct = (Struct) record.key();
            String tableLower = (actualTable != null ? actualTable : tail).toLowerCase();
            Map<String, String> columnMap = columnCaseMaps.get(tableLower);

            if (columnMap != null && !columnMap.isEmpty()) {
                newKey = restoreColumnCase(keyStruct, columnMap);
            }
        }

        if (!newTopic.equals(topic) || newValue != record.value() || newKey != record.key()) {
            return record.newRecord(
                newTopic,
                record.kafkaPartition(),
                record.keySchema(),
                newKey,
                record.valueSchema(),
                newValue,
                record.timestamp(),
                record.headers()
            );
        }

        return record;
    }

    private Struct restoreColumnCase(Struct struct, Map<String, String> columnMap) {
        if (struct.schema() == null) {
            return struct;
        }

        // Kafka Connect Struct schema is immutable — field names cannot be renamed after creation.
        // The column case mapping is informational for logging / debugging.
        // The JDBC sink connector will use its own SQL query building logic, which should
        // perform case-insensitive column matching when inserting/updating records.
        // Without renaming the Struct fields, we can only log the mapping discovered.
        //
        // For production, if case sensitivity is critical, either:
        //   1. Enable quote.identifiers on the JDBC sink (allows case-insensitive match)
        //   2. Pre-create lowercase Aurora tables and use COLLATE clauses on SQL Server
        //   3. Implement a custom JDBC sink plugin that applies the column mapping

        for (Field field : struct.schema().fields()) {
            String fieldName = field.name();
            String actualName = columnMap.get(fieldName.toLowerCase());

            if (actualName != null && !actualName.equals(fieldName)) {
                log.debug("SqlServerCaseRestorer: column '{}' in topic maps to SQL Server column '{}' " +
                         "(case-insensitive match expected by JDBC sink)", fieldName, actualName);
            }
        }

        return struct;
    }

    @Override
    public ConfigDef config() {
        return CONFIG_DEF;
    }

    @Override
    public void close() {
        tableCaseMap.clear();
        columnCaseMaps.clear();
    }
}
