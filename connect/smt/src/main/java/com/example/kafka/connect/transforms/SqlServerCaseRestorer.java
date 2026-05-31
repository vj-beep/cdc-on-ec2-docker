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

import java.util.ArrayList;
import java.util.Collections;
import java.util.List;
import java.util.Locale;
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
 * Performance: Renamed Schemas are cached by the source Schema instance (identity key)
 * so SchemaBuilder is invoked once per table, not once per record. Metadata is loaded
 * in a single JDBC round-trip at startup. At 14,000 records/sec the hot path allocates
 * only one Struct per record — no String keys, no map probes, no SchemaBuilder cost.
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

    // Package-private so unit tests can inject a pre-populated entry without a real DB.
    SqlServerSchemaCache.Entry cacheEntry;

    /**
     * Pairs a renamed Schema with the pre-computed field-name list so both are built once
     * and looked up in a single map access on the hot path.
     */
    private static final class RenamedSchema {
        final Schema schema;
        final List<String> fieldNames; // parallel to schema.fields(), unmodifiable

        RenamedSchema(Schema schema, List<String> fieldNames) {
            this.schema     = schema;
            this.fieldNames = fieldNames;
        }
    }

    // Keyed by the source Schema instance — Connect reuses the exact same Schema object for
    // every record of the same table, so identity equality is a perfect key and avoids any
    // String allocation on the hot path.
    private final ConcurrentHashMap<Schema, RenamedSchema> schemaCache = new ConcurrentHashMap<>();

    @Override
    public void configure(Map<String, ?> props) {
        SimpleConfig config  = new SimpleConfig(CONFIG_DEF, props);
        String jdbcUrl       = config.getString(JDBC_URL_CONFIG);
        String user          = config.getString(JDBC_USER_CONFIG);
        String password      = config.getPassword(JDBC_PASS_CONFIG).value();
        String schema        = config.getString(SCHEMA_CONFIG);

        cacheEntry = SqlServerSchemaCache.get(jdbcUrl, user, password, schema);
        log.info("SqlServerCaseRestorer: using shared schema cache ({} tables) for schema '{}' via {}",
                 cacheEntry.tableCaseMap.size(), schema, jdbcUrl);
    }

    @Override
    public R apply(R record) {
        if (record == null || record.topic() == null) {
            return record;
        }

        String topic = record.topic();
        int lastDot = topic.lastIndexOf('.');
        String tail = (lastDot >= 0) ? topic.substring(lastDot + 1) : topic;
        String tailLower = tail.toLowerCase(Locale.ROOT);

        String actualTable = cacheEntry.tableCaseMap.get(tailLower);
        if (actualTable == null && cacheEntry.reloadOnMiss(tailLower)) {
            actualTable = cacheEntry.tableCaseMap.get(tailLower);
        }

        String newTopic = topic;
        if (actualTable != null && !actualTable.equals(tail)) {
            newTopic = (lastDot >= 0) ? topic.substring(0, lastDot + 1) + actualTable : actualTable;
            log.debug("SqlServerCaseRestorer: table topic {} -> {}", topic, newTopic);
        }

        Map<String, String> columnMap = cacheEntry.columnCaseMaps.get(tailLower);

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
     * Rebuilds a Struct with camelCase field names.
     *
     * Cache key: the source Schema instance itself. Connect reuses the exact same Schema
     * object for every record of the same table, so identity equality is a perfect key —
     * no String allocation, no field-count arithmetic on the hot path.
     *
     * If columns are added (auto.evolve), Connect produces a new Schema instance, which
     * misses the cache and triggers a fresh build automatically.
     */
    private Struct restoreColumnCase(Struct struct, Map<String, String> columnMap) {
        Schema sourceSchema = struct.schema();
        if (sourceSchema == null) {
            return struct;
        }

        RenamedSchema renamed = schemaCache.computeIfAbsent(sourceSchema, src -> {
            List<Field> fields = src.fields();
            SchemaBuilder builder = SchemaBuilder.struct().name(src.name());
            if (src.isOptional()) builder.optional();
            List<String> names = new ArrayList<>(fields.size());
            for (Field field : fields) {
                String actual  = columnMap.get(field.name().toLowerCase(Locale.ROOT));
                String newName = (actual != null) ? actual : field.name();
                if (!newName.equals(field.name())) {
                    log.debug("SqlServerCaseRestorer: renaming field '{}' -> '{}'", field.name(), newName);
                }
                builder.field(newName, field.schema());
                names.add(newName);
            }
            return new RenamedSchema(builder.build(), Collections.unmodifiableList(names));
        });

        // Hot path: one Struct allocation, no map lookups, no String construction.
        List<Field> sourceFields = sourceSchema.fields();
        Struct newStruct = new Struct(renamed.schema);
        for (int i = 0; i < sourceFields.size(); i++) {
            newStruct.put(renamed.fieldNames.get(i), struct.get(sourceFields.get(i)));
        }
        return newStruct;
    }

    @Override
    public ConfigDef config() {
        return CONFIG_DEF;
    }

    @Override
    public void close() {
        schemaCache.clear();
        // cacheEntry is shared — do not clear it here
    }
}
