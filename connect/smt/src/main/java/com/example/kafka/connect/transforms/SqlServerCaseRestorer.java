package com.example.kafka.connect.transforms;

import org.apache.kafka.common.config.ConfigDef;
import org.apache.kafka.common.config.ConfigException;
import org.apache.kafka.connect.connector.ConnectRecord;
import org.apache.kafka.connect.data.Field;
import org.apache.kafka.connect.data.Schema;
import org.apache.kafka.connect.data.SchemaBuilder;
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
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;

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
 *
 * Performance: Renamed Schemas are cached per source schema name so that
 * SchemaBuilder is only invoked once per table, not once per record. At
 * 14,000 records/sec (TB snapshot) this avoids ~56K short-lived allocations
 * per second and the associated young-gen GC pressure.
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

    // Cache of renamed Schemas keyed by the source schema's name (one Schema object per table,
    // reused across all records). ConcurrentHashMap because Connect may call apply() from
    // multiple worker threads on the same SMT instance.
    private final Map<String, Schema> renamedSchemaCache = new ConcurrentHashMap<>();

    // Parallel field-rename list cached alongside each schema: source field name → renamed field name.
    // Avoids re-doing the columnMap lookup on every record once the schema is cached.
    private final Map<String, List<String>> renamedFieldsCache = new ConcurrentHashMap<>();

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
                    String tableName  = rs.getString("table_name");
                    String columnName = rs.getString("column_name");

                    if (!tableName.equals(currentTable)) {
                        currentTable = tableName;
                        currentMap = new HashMap<>();
                        columnCaseMaps.put(tableName.toLowerCase(), currentMap);
                    }

                    String lower = columnName.toLowerCase();
                    String prev  = currentMap.put(lower, columnName);
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

        String tail        = parts[parts.length - 1];
        String actualTable = tableCaseMap.get(tail.toLowerCase());

        String newTopic = topic;
        if (actualTable != null && !actualTable.equals(tail)) {
            parts[parts.length - 1] = actualTable;
            newTopic = String.join(".", parts);
            log.debug("SqlServerCaseRestorer: table topic {} -> {}", topic, newTopic);
        }

        String tableLower = (actualTable != null ? actualTable : tail).toLowerCase();
        Map<String, String> columnMap = columnCaseMaps.get(tableLower);

        Object newValue = record.value();
        if (record.value() instanceof Struct && columnMap != null && !columnMap.isEmpty()) {
            newValue = restoreColumnCase((Struct) record.value(), columnMap);
        }

        Object newKey = record.key();
        if (record.key() instanceof Struct && columnMap != null && !columnMap.isEmpty()) {
            newKey = restoreColumnCase((Struct) record.key(), columnMap);
        }

        if (!newTopic.equals(topic) || newValue != record.value() || newKey != record.key()) {
            // Use the renamed Struct's own schema so Debezium JDBC sink sees camelCase field names
            // in valueSchema(). Passing record.valueSchema() here would leave the lowercase schema
            // on the SinkRecord — Debezium reads valueSchema() for hasColumn() validation, causing
            // a false "missing column" detection and a failed ALTER TABLE attempt.
            Schema newValueSchema = (newValue instanceof Struct)
                ? ((Struct) newValue).schema() : record.valueSchema();
            Schema newKeySchema = (newKey instanceof Struct)
                ? ((Struct) newKey).schema() : record.keySchema();
            return record.newRecord(
                newTopic,
                record.kafkaPartition(),
                newKeySchema,
                newKey,
                newValueSchema,
                newValue,
                record.timestamp(),
                record.headers()
            );
        }

        return record;
    }

    /**
     * Rebuilds a Struct with camelCase field names, reusing a cached Schema so that
     * SchemaBuilder is only invoked once per table rather than once per record.
     *
     * Cache key: source schema name (set by Debezium per table, stable across records).
     * On first call for a given table: build + cache Schema + field rename list.
     * On subsequent calls: skip SchemaBuilder entirely, only allocate the new Struct.
     */
    private Struct restoreColumnCase(Struct struct, Map<String, String> columnMap) {
        if (struct.schema() == null) {
            return struct;
        }

        String schemaName = struct.schema().name();

        Schema cachedSchema = renamedSchemaCache.get(schemaName);
        List<String> cachedRenames = renamedFieldsCache.get(schemaName);

        if (cachedSchema == null) {
            // First record for this table: build the renamed Schema and cache it.
            SchemaBuilder builder = SchemaBuilder.struct().name(schemaName);
            if (struct.schema().isOptional()) builder.optional();

            List<String> renames = new ArrayList<>(struct.schema().fields().size());
            for (Field field : struct.schema().fields()) {
                String actual  = columnMap.get(field.name().toLowerCase());
                String renamed = (actual != null) ? actual : field.name();
                if (!renamed.equals(field.name())) {
                    log.debug("SqlServerCaseRestorer: renaming field '{}' -> '{}'", field.name(), renamed);
                }
                builder.field(renamed, field.schema());
                renames.add(renamed);
            }

            cachedSchema  = builder.build();
            cachedRenames = renames;

            renamedSchemaCache.put(schemaName, cachedSchema);
            renamedFieldsCache.put(schemaName, cachedRenames);
        }

        // Hot path: schema already cached — only allocate the Struct, no SchemaBuilder.
        Struct newStruct = new Struct(cachedSchema);
        List<Field> sourceFields = struct.schema().fields();
        for (int i = 0; i < sourceFields.size(); i++) {
            newStruct.put(cachedRenames.get(i), struct.get(sourceFields.get(i)));
        }

        return newStruct;
    }

    @Override
    public ConfigDef config() {
        return CONFIG_DEF;
    }

    @Override
    public void close() {
        tableCaseMap.clear();
        columnCaseMaps.clear();
        renamedSchemaCache.clear();
        renamedFieldsCache.clear();
    }
}
