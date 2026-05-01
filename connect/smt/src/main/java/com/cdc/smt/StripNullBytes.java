package com.cdc.smt;

import org.apache.kafka.common.config.ConfigDef;
import org.apache.kafka.connect.connector.ConnectRecord;
import org.apache.kafka.connect.data.Field;
import org.apache.kafka.connect.data.Schema;
import org.apache.kafka.connect.data.Struct;
import org.apache.kafka.connect.transforms.Transformation;

import java.util.HashMap;
import java.util.Map;

/**
 * Strips null bytes (0x00) from all STRING fields in the record value.
 * PostgreSQL UTF-8 encoding rejects chr(0) - this prevents batch-level
 * DataException that bypasses errors.tolerance=all and crashes the sink task.
 */
public class StripNullBytes<R extends ConnectRecord<R>> implements Transformation<R> {

    private static final char NULL_BYTE = (char) 0;

    @Override
    public R apply(R record) {
        if (record.value() == null) return record;
        if (!(record.value() instanceof Struct)) return record;

        Struct original = (Struct) record.value();
        Schema schema = original.schema();
        boolean changed = false;

        Map<String, Object> updatedFields = new HashMap<>();
        for (Field field : schema.fields()) {
            if (field.schema().type() == Schema.Type.STRING) {
                String val = original.getString(field.name());
                if (val != null && val.indexOf(NULL_BYTE) >= 0) {
                    updatedFields.put(field.name(), val.replace(String.valueOf(NULL_BYTE), ""));
                    changed = true;
                }
            }
        }

        if (!changed) return record;

        Struct updated = new Struct(schema);
        for (Field field : schema.fields()) {
            if (updatedFields.containsKey(field.name())) {
                updated.put(field.name(), updatedFields.get(field.name()));
            } else {
                updated.put(field.name(), original.get(field));
            }
        }

        return record.newRecord(
            record.topic(), record.kafkaPartition(),
            record.keySchema(), record.key(),
            schema, updated,
            record.timestamp()
        );
    }

    @Override public ConfigDef config() { return new ConfigDef(); }
    @Override public void configure(Map<String, ?> configs) {}
    @Override public void close() {}
}
