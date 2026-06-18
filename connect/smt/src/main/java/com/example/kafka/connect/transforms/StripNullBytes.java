package com.example.kafka.connect.transforms;

import org.apache.kafka.common.config.ConfigDef;
import org.apache.kafka.connect.connector.ConnectRecord;
import org.apache.kafka.connect.data.Field;
import org.apache.kafka.connect.data.Schema;
import org.apache.kafka.connect.data.Struct;
import org.apache.kafka.connect.transforms.Transformation;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import java.nio.ByteBuffer;
import java.util.HashMap;
import java.util.Map;

/**
 * Strips null bytes (0x00) from all STRING and BYTES fields in a Kafka Connect record.
 *
 * Problem: SQL Server VARBINARY columns may contain embedded chr(0)/null bytes.
 * These propagate through Debezium as BYTES fields. PostgreSQL's text-mode JDBC
 * driver rejects strings containing null bytes with:
 *   "ERROR: invalid byte sequence for encoding UTF8: 0x00"
 * Aurora JDBC sink calls getString() on BYTES columns, triggering this error.
 *
 * Solution: Strip 0x00 from all STRING fields (direct null-byte injection) and
 * BYTES fields (binary columns with embedded nulls) before the sink writes them.
 *
 * All Kafka Connect framework classes are provided at runtime — no bundled deps.
 */
public class StripNullBytes<R extends ConnectRecord<R>> implements Transformation<R> {

    private static final Logger log = LoggerFactory.getLogger(StripNullBytes.class);

    @Override
    public void configure(Map<String, ?> configs) {
        // no configuration needed
    }

    @Override
    public ConfigDef config() {
        return new ConfigDef();
    }

    @Override
    public R apply(R record) {
        if (record.value() == null) {
            return record;
        }

        Schema valueSchema = record.valueSchema();

        if (valueSchema != null && valueSchema.type() == Schema.Type.STRUCT) {
            Struct original = (Struct) record.value();
            Struct updated = new Struct(valueSchema);
            boolean changed = false;

            for (Field field : valueSchema.fields()) {
                Object fieldValue = original.get(field);
                Object stripped = stripField(field.schema(), fieldValue);
                updated.put(field, stripped);
                if (stripped != fieldValue) {
                    changed = true;
                }
            }

            if (changed) {
                return record.newRecord(
                        record.topic(), record.kafkaPartition(),
                        record.keySchema(), record.key(),
                        valueSchema, updated,
                        record.timestamp(), record.headers()
                );
            }
            return record;
        }

        // Schemaless map
        if (record.value() instanceof Map) {
            @SuppressWarnings("unchecked")
            Map<String, Object> original = (Map<String, Object>) record.value();
            Map<String, Object> updated = new HashMap<>(original.size());
            boolean changed = false;

            for (Map.Entry<String, Object> entry : original.entrySet()) {
                Object stripped = stripSchemaless(entry.getValue());
                updated.put(entry.getKey(), stripped);
                if (stripped != entry.getValue()) {
                    changed = true;
                }
            }

            if (changed) {
                return record.newRecord(
                        record.topic(), record.kafkaPartition(),
                        record.keySchema(), record.key(),
                        null, updated,
                        record.timestamp(), record.headers()
                );
            }
        }

        return record;
    }

    private Object stripField(Schema schema, Object value) {
        if (value == null) return null;

        switch (schema.type()) {
            case STRING:
                return stripString((String) value);
            case BYTES:
                if (value instanceof byte[]) {
                    return stripBytes((byte[]) value);
                }
                if (value instanceof ByteBuffer) {
                    ByteBuffer buf = (ByteBuffer) value;
                    byte[] arr = new byte[buf.remaining()];
                    buf.duplicate().get(arr);
                    return ByteBuffer.wrap(stripBytes(arr));
                }
                return value;
            default:
                return value;
        }
    }

    private Object stripSchemaless(Object value) {
        if (value instanceof String) return stripString((String) value);
        if (value instanceof byte[]) return stripBytes((byte[]) value);
        if (value instanceof ByteBuffer) {
            ByteBuffer buf = (ByteBuffer) value;
            byte[] arr = new byte[buf.remaining()];
            buf.duplicate().get(arr);
            return ByteBuffer.wrap(stripBytes(arr));
        }
        return value;
    }

    private String stripString(String s) {
        if (s.indexOf('\0') == -1) return s;
        return s.replace("\0", "");
    }

    private byte[] stripBytes(byte[] bytes) {
        int nullCount = 0;
        for (byte b : bytes) {
            if (b == 0x00) nullCount++;
        }
        if (nullCount == 0) return bytes;

        byte[] result = new byte[bytes.length - nullCount];
        int idx = 0;
        for (byte b : bytes) {
            if (b != 0x00) result[idx++] = b;
        }
        log.debug("StripNullBytes: removed {} null byte(s) from BYTES field", nullCount);
        return result;
    }

    @Override
    public void close() {
        // nothing to release
    }
}
