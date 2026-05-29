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
        @DisplayName("Populates table map from INFORMATION_SCHEMA result set")
        void populatesMapFromResultSet() throws Exception {
            when(conn.prepareStatement(anyString())).thenReturn(ps);
            when(ps.executeQuery()).thenReturn(rs);
            // Simulate two rows: FlagSet, workItem
            when(rs.next()).thenReturn(true, true, false);
            when(rs.getString("TABLE_NAME")).thenReturn("FlagSet", "workItem");

            try (MockedStatic<DriverManager> dm = mockStatic(DriverManager.class)) {
                dm.when(() -> DriverManager.getConnection(anyString(), anyString(), anyString()))
                  .thenReturn(conn);

                smt.configure(configProps());
            }

            assertEquals("FlagSet",  smt.tableCaseMap.get("flagset"));
            assertEquals("workItem", smt.tableCaseMap.get("workitem"));
            assertEquals(2, smt.tableCaseMap.size());
        }

        @Test
        @DisplayName("Throws ConfigException when SQL Server is unreachable")
        void throwsOnConnectionFailure() throws Exception {
            try (MockedStatic<DriverManager> dm = mockStatic(DriverManager.class)) {
                dm.when(() -> DriverManager.getConnection(anyString(), anyString(), anyString()))
                  .thenThrow(new SQLException("Connection refused"));

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
