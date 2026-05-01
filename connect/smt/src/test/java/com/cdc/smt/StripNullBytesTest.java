package com.cdc.smt;

import org.apache.kafka.connect.data.Schema;
import org.apache.kafka.connect.data.SchemaBuilder;
import org.apache.kafka.connect.data.Struct;
import org.apache.kafka.connect.source.SourceRecord;
import org.junit.Test;

import java.util.Collections;

import static org.junit.Assert.*;

public class StripNullBytesTest {

    private final StripNullBytes<SourceRecord> smt = new StripNullBytes<>();

    // Exact scenario from the stack trace:
    //   INSERT INTO public.inferencetypestatus ... VALUES (..., chr(0), ...)
    @Test
    public void nullByteStrippedFromStatusField() {
        Schema schema = SchemaBuilder.struct()
            .field("inferencetypeid", Schema.INT32_SCHEMA)
            .field("status", Schema.STRING_SCHEMA)
            .field("label", Schema.STRING_SCHEMA)
            .build();

        Struct value = new Struct(schema)
            .put("inferencetypeid", 101)
            .put("status", String.valueOf((char) 0))
            .put("label", "New");

        Struct out = (Struct) smt.apply(makeRecord(schema, value)).value();
        assertEquals("", out.getString("status"));
        assertEquals("New", out.getString("label"));
    }

    @Test
    public void cleanRecordReturnedAsIs() {
        Schema schema = SchemaBuilder.struct()
            .field("id", Schema.INT32_SCHEMA)
            .field("name", Schema.STRING_SCHEMA)
            .build();

        Struct value = new Struct(schema).put("id", 1).put("name", "Alice");
        SourceRecord record = makeRecord(schema, value);
        assertSame(record, smt.apply(record));
    }

    @Test
    public void nullValueFieldUntouched() {
        Schema schema = SchemaBuilder.struct()
            .field("id", Schema.INT32_SCHEMA)
            .field("note", Schema.OPTIONAL_STRING_SCHEMA)
            .build();

        Struct value = new Struct(schema).put("id", 5).put("note", (String) null);
        SourceRecord record = makeRecord(schema, value);
        assertSame(record, smt.apply(record));
    }

    @Test
    public void tombstoneRecordPassthrough() {
        SourceRecord tombstone = new SourceRecord(
            Collections.emptyMap(), Collections.emptyMap(),
            "topic", Schema.STRING_SCHEMA, "key", null, null);
        assertSame(tombstone, smt.apply(tombstone));
    }

    @Test
    public void multipleFieldsAllStripped() {
        Schema schema = SchemaBuilder.struct()
            .field("col_a", Schema.STRING_SCHEMA)
            .field("col_b", Schema.STRING_SCHEMA)
            .field("col_c", Schema.STRING_SCHEMA)
            .build();

        String nul = String.valueOf((char) 0);
        Struct value = new Struct(schema)
            .put("col_a", "hello" + nul + "world")
            .put("col_b", nul + "leading")
            .put("col_c", "trailing" + nul);

        Struct out = (Struct) smt.apply(makeRecord(schema, value)).value();
        assertEquals("helloworld", out.getString("col_a"));
        assertEquals("leading",    out.getString("col_b"));
        assertEquals("trailing",   out.getString("col_c"));
    }

    @Test
    public void mixedCleanAndDirtyFields() {
        Schema schema = SchemaBuilder.struct()
            .field("id", Schema.INT32_SCHEMA)
            .field("dirty", Schema.STRING_SCHEMA)
            .field("clean", Schema.STRING_SCHEMA)
            .build();

        Struct value = new Struct(schema)
            .put("id", 42)
            .put("dirty", String.valueOf((char) 0))
            .put("clean", "untouched");

        Struct out = (Struct) smt.apply(makeRecord(schema, value)).value();
        assertEquals("",          out.getString("dirty"));
        assertEquals("untouched", out.getString("clean"));
        assertEquals(42,          out.get("id"));
    }

    @Test
    public void nullByteOnlyValueBecomesEmptyString() {
        Schema schema = SchemaBuilder.struct()
            .field("status", Schema.STRING_SCHEMA)
            .build();

        Struct value = new Struct(schema).put("status", String.valueOf((char) 0));
        Struct out = (Struct) smt.apply(makeRecord(schema, value)).value();
        assertEquals("", out.getString("status"));
    }

    private SourceRecord makeRecord(Schema schema, Struct value) {
        return new SourceRecord(
            Collections.emptyMap(), Collections.emptyMap(),
            "test.topic", Schema.STRING_SCHEMA, "key", schema, value);
    }
}
