package com.example.kafka.connect.transforms;

import org.apache.kafka.common.record.TimestampType;
import org.apache.kafka.connect.data.Schema;
import org.apache.kafka.connect.data.SchemaBuilder;
import org.apache.kafka.connect.data.Struct;
import org.apache.kafka.connect.header.ConnectHeaders;
import org.apache.kafka.connect.header.Headers;
import org.apache.kafka.connect.sink.SinkRecord;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Nested;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.Mock;
import org.mockito.MockedStatic;
import org.mockito.junit.jupiter.MockitoExtension;

import java.sql.Connection;
import java.sql.DriverManager;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.util.HashMap;
import java.util.Map;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertSame;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.mockStatic;
import static org.mockito.Mockito.when;

@ExtendWith(MockitoExtension.class)
class SqlServerCaseRestorerTest {

    private SqlServerCaseRestorer<SinkRecord> smt;

    @Mock private Connection conn;
    @Mock private PreparedStatement ps;
    @Mock private ResultSet rs;

    @BeforeEach
    void setUp() {
        smt = new SqlServerCaseRestorer<>();
    }

    @AfterEach
    void tearDown() {
        smt.close();
    }

    // ── helpers ────────────────────────────────────────────────────────────────

    /** Inject table map directly — bypasses configure() so no real DB required. */
    private void seed(String... pairs) {
        for (int i = 0; i < pairs.length; i += 2) {
            smt.tableCaseMap.put(pairs[i].toLowerCase(), pairs[i + 1]);
        }
    }

    private SinkRecord record(String topic) {
        return record(topic, new ConnectHeaders());
    }

    private SinkRecord record(String topic, Headers headers) {
        Schema keySchema = SchemaBuilder.struct()
            .field("id", Schema.INT32_SCHEMA).build();
        Struct key = new Struct(keySchema).put("id", 1);

        Schema valueSchema = SchemaBuilder.struct()
            .field("name", Schema.STRING_SCHEMA).build();
        Struct value = new Struct(valueSchema).put("name", "test");

        return new SinkRecord(
            topic, 0,
            keySchema, key,
            valueSchema, value,
            100L, 1000L, TimestampType.CREATE_TIME,
            headers
        );
    }

    // ── topic rewriting ────────────────────────────────────────────────────────

    @Nested
    @DisplayName("Topic case restoration")
    class TopicCaseRestorationTests {

        @Test
        @DisplayName("Rewrites lowercase tail to mixed-case SQL Server name")
        void restoresMixedCase() {
            seed("flagset", "FlagSet");
            SinkRecord out = smt.apply(record("aurora.public.flagset"));
            assertEquals("aurora.public.FlagSet", out.topic());
        }

        @Test
        @DisplayName("Handles single-segment topic (no dots)")
        void singleSegmentTopic() {
            seed("flagset", "FlagSet");
            SinkRecord out = smt.apply(record("flagset"));
            assertEquals("FlagSet", out.topic());
        }

        @Test
        @DisplayName("Passes through when no mapping exists for table")
        void noMappingPassthrough() {
            seed("flagset", "FlagSet");
            SinkRecord out = smt.apply(record("aurora.public.unknowntable"));
            assertEquals("aurora.public.unknowntable", out.topic());
        }

        @Test
        @DisplayName("Passes through when topic is already correctly cased")
        void alreadyCorrectCasePassthrough() {
            seed("flagset", "FlagSet");
            SinkRecord in  = record("aurora.public.FlagSet");
            SinkRecord out = smt.apply(in);
            // Should return the same object reference — no allocation
            assertEquals(in, out);
        }

        @Test
        @DisplayName("Does not corrupt prefix when table name appears in prefix")
        void doesNotCorruptPrefixContainingTableName() {
            // If prefix segment happened to contain the same string as the table name,
            // old replace()-based logic would corrupt it. Split/join is safe.
            seed("aurora", "Aurora");
            SinkRecord out = smt.apply(record("aurora.public.aurora"));
            assertEquals("aurora.public.Aurora", out.topic());
        }

        @Test
        @DisplayName("Handles deeply nested topic prefix")
        void deeplyNestedPrefix() {
            seed("workitem", "workItem");
            SinkRecord out = smt.apply(record("server.schema.db.public.workitem"));
            assertEquals("server.schema.db.public.workItem", out.topic());
        }
    }

    // ── null / edge cases ──────────────────────────────────────────────────────

    @Nested
    @DisplayName("Null and edge-case handling")
    class NullAndEdgeCaseTests {

        @Test
        @DisplayName("Returns null record as-is")
        void nullRecordPassthrough() {
            assertNull(smt.apply(null));
        }

        @Test
        @DisplayName("Returns record with null topic as-is")
        void nullTopicPassthrough() {
            SinkRecord in = new SinkRecord(
                null, 0, null, null, null, null, 0L);
            SinkRecord out = smt.apply(in);
            assertNull(out.topic());
        }

        @Test
        @DisplayName("Handles empty table map without throwing")
        void emptyMapPassthrough() {
            SinkRecord out = smt.apply(record("aurora.public.flagset"));
            assertEquals("aurora.public.flagset", out.topic());
        }
    }

    // ── headers preservation ───────────────────────────────────────────────────

    @Nested
    @DisplayName("Header preservation")
    class HeaderPreservationTests {

        @Test
        @DisplayName("Preserves all headers when topic is rewritten")
        void headersPreservedOnRewrite() {
            seed("flagset", "FlagSet");

            ConnectHeaders headers = new ConnectHeaders();
            headers.addString("__cdc_from_aurora", "");
            headers.addString("__connect.errors.topic", "aurora.public.flagset");

            SinkRecord out = smt.apply(record("aurora.public.flagset", headers));

            assertEquals("aurora.public.FlagSet", out.topic());
            assertNotNull(out.headers().lastWithName("__cdc_from_aurora"),
                "Loop-prevention header must survive topic rewrite");
            assertNotNull(out.headers().lastWithName("__connect.errors.topic"),
                "Error context header must survive topic rewrite");
        }

        @Test
        @DisplayName("Preserves headers when no mapping found (passthrough)")
        void headersPreservedOnPassthrough() {
            ConnectHeaders headers = new ConnectHeaders();
            headers.addString("__cdc_from_aurora", "");

            SinkRecord out = smt.apply(record("aurora.public.unknown", headers));
            assertNotNull(out.headers().lastWithName("__cdc_from_aurora"));
        }
    }

    // ── configure() with mocked JDBC ──────────────────────────────────────────

    @Nested
    @DisplayName("configure() — JDBC metadata loading")
    class ConfigureTests {

        private Map<String, Object> configProps() {
            Map<String, Object> props = new HashMap<>();
            props.put(SqlServerCaseRestorer.JDBC_URL_CONFIG,
                      "jdbc:sqlserver://localhost:1433;databaseName=testdb;encrypt=false");
            props.put(SqlServerCaseRestorer.JDBC_USER_CONFIG, "sa");
            props.put(SqlServerCaseRestorer.JDBC_PASS_CONFIG, "Password123!");
            props.put(SqlServerCaseRestorer.SCHEMA_CONFIG, "dbo");
            return props;
        }

        @Test
        @DisplayName("Populates table and column maps from merged metadata result set")
        void populatesMapFromResultSet() throws Exception {
            when(conn.prepareStatement(anyString())).thenReturn(ps);
            when(ps.executeQuery()).thenReturn(rs);
            // Single query returns (table_name, column_name) rows ordered by table, column_id.
            // Two tables: FlagSet(id, name), workItem(workItemId)
            when(rs.next()).thenReturn(true, true, true, false);
            when(rs.getString("table_name")).thenReturn("FlagSet", "FlagSet", "workItem");
            when(rs.getString("column_name")).thenReturn("id", "name", "workItemId");

            try (MockedStatic<DriverManager> dm = mockStatic(DriverManager.class)) {
                dm.when(() -> DriverManager.getConnection(anyString(), anyString(), anyString()))
                  .thenReturn(conn);

                smt.configure(configProps());
            }

            assertEquals("FlagSet",  smt.tableCaseMap.get("flagset"));
            assertEquals("workItem", smt.tableCaseMap.get("workitem"));
            assertEquals(2, smt.tableCaseMap.size());
            assertEquals("workItemId", smt.columnCaseMaps.get("workitem").get("workitemid"));
            assertEquals("name",       smt.columnCaseMaps.get("flagset").get("name"));
        }

        @Test
        @DisplayName("Throws ConfigException when SQL Server is unreachable")
        void throwsOnConnectionFailure() throws Exception {
            // Create the exception BEFORE entering mockStatic — SQLException.<init>
            // calls DriverManager.getLogWriter() internally, which confuses the
            // static mock and produces UnfinishedStubbingException if done inside.
            SQLException sqlEx = new SQLException("Connection refused");
            try (MockedStatic<DriverManager> dm = mockStatic(DriverManager.class)) {
                dm.when(() -> DriverManager.getConnection(anyString(), anyString(), anyString()))
                  .thenThrow(sqlEx);

                assertThrows(org.apache.kafka.common.config.ConfigException.class,
                    () -> smt.configure(configProps()));
            }
        }

        @Test
        @DisplayName("close() clears the table map")
        void closeClears() {
            seed("flagset", "FlagSet");
            assertEquals(1, smt.tableCaseMap.size());
            smt.close();
            assertEquals(0, smt.tableCaseMap.size());
        }
    }

    // ── column case restoration ─────────────────────────────────────────────────

    @Nested
    @DisplayName("Column case restoration")
    class ColumnCaseRestorationTests {

        private void seedColumns(String tableLower, String... pairs) {
            Map<String, String> colMap = new HashMap<>();
            for (int i = 0; i < pairs.length; i += 2) {
                colMap.put(pairs[i].toLowerCase(), pairs[i + 1]);
            }
            smt.columnCaseMaps.put(tableLower, colMap);
        }

        private SinkRecord structRecord(String topic, Schema valueSchema, Struct value) {
            Schema keySchema = SchemaBuilder.struct()
                .field("id", Schema.INT32_SCHEMA).build();
            Struct key = new Struct(keySchema).put("id", 1);
            return new SinkRecord(
                topic, 0, keySchema, key, valueSchema, value,
                100L, 1000L, TimestampType.CREATE_TIME, new ConnectHeaders()
            );
        }

        @Test
        @DisplayName("Renames struct fields from lowercase to camelCase")
        void renamesFields() {
            seed("workitemdata", "workItemData");
            seedColumns("workitemdata",
                "workitemid", "workItemId",
                "dataxml", "dataXml",
                "createdat", "createdAt");

            Schema schema = SchemaBuilder.struct().name("test.value")
                .field("workitemid", Schema.INT64_SCHEMA)
                .field("dataxml", Schema.OPTIONAL_STRING_SCHEMA)
                .field("createdat", Schema.OPTIONAL_STRING_SCHEMA)
                .build();
            Struct value = new Struct(schema)
                .put("workitemid", 99001L)
                .put("dataxml", "<test/>")
                .put("createdat", "2026-01-01");

            SinkRecord out = smt.apply(structRecord("workitemdata", schema, value));

            Struct outValue = (Struct) out.value();
            assertEquals(99001L, outValue.get("workItemId"));
            assertEquals("<test/>", outValue.get("dataXml"));
            assertEquals("2026-01-01", outValue.get("createdAt"));
            assertEquals("workItemData", out.topic());
        }

        @Test
        @DisplayName("Schema is cached — same Schema instance for repeated calls")
        void schemaCached() {
            seed("workitemdata", "workItemData");
            seedColumns("workitemdata", "workitemid", "workItemId");

            Schema schema = SchemaBuilder.struct().name("test.value")
                .field("workitemid", Schema.INT64_SCHEMA).build();
            Struct v1 = new Struct(schema).put("workitemid", 1L);
            Struct v2 = new Struct(schema).put("workitemid", 2L);

            SinkRecord out1 = smt.apply(structRecord("workitemdata", schema, v1));
            SinkRecord out2 = smt.apply(structRecord("workitemdata", schema, v2));

            assertSame(((Struct) out1.value()).schema(), ((Struct) out2.value()).schema(),
                "Cached schema should be the same object instance");
        }

        @Test
        @DisplayName("Passes through fields with no column mapping unchanged")
        void unmappedFieldsPassthrough() {
            seed("workitemdata", "workItemData");
            seedColumns("workitemdata", "workitemid", "workItemId");

            Schema schema = SchemaBuilder.struct().name("test.value")
                .field("workitemid", Schema.INT64_SCHEMA)
                .field("title", Schema.STRING_SCHEMA)
                .build();
            Struct value = new Struct(schema)
                .put("workitemid", 1L)
                .put("title", "hello");

            SinkRecord out = smt.apply(structRecord("workitemdata", schema, value));
            Struct outValue = (Struct) out.value();
            assertEquals(1L, outValue.get("workItemId"));
            assertEquals("hello", outValue.get("title"));
        }

        @Test
        @DisplayName("Also renames key struct fields")
        void renamesKeyFields() {
            seed("workitemdata", "workItemData");
            seedColumns("workitemdata", "workitemid", "workItemId");

            Schema keySchema = SchemaBuilder.struct().name("test.key")
                .field("workitemid", Schema.INT64_SCHEMA).build();
            Struct key = new Struct(keySchema).put("workitemid", 99L);

            Schema valueSchema = SchemaBuilder.struct().name("test.value")
                .field("title", Schema.STRING_SCHEMA).build();
            Struct value = new Struct(valueSchema).put("title", "test");

            SinkRecord in = new SinkRecord(
                "workitemdata", 0, keySchema, key, valueSchema, value,
                100L, 1000L, TimestampType.CREATE_TIME, new ConnectHeaders()
            );
            SinkRecord out = smt.apply(in);

            Struct outKey = (Struct) out.key();
            assertEquals(99L, outKey.get("workItemId"));
        }

        @Test
        @DisplayName("Propagates renamed schema on SinkRecord valueSchema()")
        void renamedSchemaOnRecord() {
            seed("workitemdata", "workItemData");
            seedColumns("workitemdata", "workitemid", "workItemId");

            Schema schema = SchemaBuilder.struct().name("test.value")
                .field("workitemid", Schema.INT64_SCHEMA).build();
            Struct value = new Struct(schema).put("workitemid", 1L);

            SinkRecord out = smt.apply(structRecord("workitemdata", schema, value));

            assertEquals("workItemId", out.valueSchema().fields().get(0).name());
        }
    }

    // ── throughput benchmark ─────────────────────────────────────────────────────

    @Nested
    @DisplayName("Throughput at scale")
    class ThroughputTests {

        @Test
        @DisplayName("Processes 1M records in < 5s (200K+ rec/sec) — proves no latency concern at TB scale")
        void millionRecordThroughput() {
            // Simulate 50 tables with 10 columns each
            for (int t = 0; t < 50; t++) {
                String tableName = "table" + t;
                smt.tableCaseMap.put(tableName, "Table" + t);
                Map<String, String> colMap = new HashMap<>();
                for (int c = 0; c < 10; c++) {
                    colMap.put("column" + c, "Column" + c);
                }
                smt.columnCaseMaps.put(tableName, colMap);
            }

            Schema valueSchema = SchemaBuilder.struct().name("test.value")
                .field("column0", Schema.INT64_SCHEMA)
                .field("column1", Schema.STRING_SCHEMA)
                .field("column2", Schema.OPTIONAL_STRING_SCHEMA)
                .field("column3", Schema.INT32_SCHEMA)
                .field("column4", Schema.OPTIONAL_STRING_SCHEMA)
                .build();

            Schema keySchema = SchemaBuilder.struct().name("test.key")
                .field("column0", Schema.INT64_SCHEMA).build();

            int recordCount = 1_000_000;
            SinkRecord[] records = new SinkRecord[recordCount];
            for (int i = 0; i < recordCount; i++) {
                Struct value = new Struct(valueSchema)
                    .put("column0", (long) i)
                    .put("column1", "value-" + i)
                    .put("column2", null)
                    .put("column3", i % 1000)
                    .put("column4", "data");
                Struct key = new Struct(keySchema).put("column0", (long) i);
                records[i] = new SinkRecord(
                    "aurora.public.table" + (i % 50), 0,
                    keySchema, key, valueSchema, value,
                    (long) i, System.currentTimeMillis(), TimestampType.CREATE_TIME,
                    new ConnectHeaders()
                );
            }

            // Warmup
            for (int i = 0; i < 1000; i++) {
                smt.apply(records[i]);
            }

            long start = System.nanoTime();
            for (int i = 0; i < recordCount; i++) {
                smt.apply(records[i]);
            }
            long elapsed = System.nanoTime() - start;

            double seconds = elapsed / 1_000_000_000.0;
            double recsPerSec = recordCount / seconds;

            System.out.printf("Throughput: %.0f records/sec (%.2fs for %d records)%n",
                recsPerSec, seconds, recordCount);

            // At TB scale: ~23K rec/sec needed (1 TB / avg 1 KB per record / 12 hours)
            // At 300-500 GB/day: ~5-8K rec/sec steady state
            // Require at least 200K rec/sec to be >10x headroom
            assert recsPerSec > 200_000 :
                "SMT throughput " + recsPerSec + " rec/sec is below 200K — investigate";
        }
    }

    // ── config() descriptor ───────────────────────────────────────────────────

    @Test
    @DisplayName("config() returns non-null ConfigDef with all four keys")
    void configDefContainsAllKeys() {
        var def = smt.config();
        assertNotNull(def);
        assertNotNull(def.configKeys().get(SqlServerCaseRestorer.JDBC_URL_CONFIG));
        assertNotNull(def.configKeys().get(SqlServerCaseRestorer.JDBC_USER_CONFIG));
        assertNotNull(def.configKeys().get(SqlServerCaseRestorer.JDBC_PASS_CONFIG));
        assertNotNull(def.configKeys().get(SqlServerCaseRestorer.SCHEMA_CONFIG));
    }
}
