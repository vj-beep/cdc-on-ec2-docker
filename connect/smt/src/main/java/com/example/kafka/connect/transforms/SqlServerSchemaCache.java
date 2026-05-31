package com.example.kafka.connect.transforms;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import java.sql.Connection;
import java.sql.DriverManager;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.util.Collections;
import java.util.HashMap;
import java.util.Locale;
import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.atomic.AtomicLong;

/**
 * Shared static schema cache for SqlServerCaseRestorer and SqlServerColumnNamingStrategy.
 *
 * Both classes are loaded by different parts of the framework (SMT chain vs JDBC sink internals)
 * and cannot share instances. This static cache lets whoever initialises first load the metadata
 * from SQL Server; the second caller reuses the already-loaded entry.
 *
 * Reload-on-miss: if a column or table name is not found in the cache, a reload is triggered
 * (at most once per RELOAD_COOLDOWN_MS) to handle schema evolution without requiring a connector
 * restart.
 */
public final class SqlServerSchemaCache {

    private static final Logger log = LoggerFactory.getLogger(SqlServerSchemaCache.class);

    static final long RELOAD_COOLDOWN_MS = 60_000;

    /** One entry per (jdbcUrl + schema) pair. */
    static final ConcurrentHashMap<String, Entry> CACHE = new ConcurrentHashMap<>();

    private SqlServerSchemaCache() {}

    static String cacheKey(String jdbcUrl, String schema) {
        return jdbcUrl + "#" + schema;
    }

    /** Returns the cache entry for this (jdbcUrl, schema), loading it if absent. */
    public static Entry get(String jdbcUrl, String user, String password, String schema) {
        String key = cacheKey(jdbcUrl, schema);
        Entry entry = CACHE.get(key);
        if (entry == null) {
            Entry newEntry = new Entry(jdbcUrl, user, password, schema);
            newEntry.load();
            Entry existing = CACHE.putIfAbsent(key, newEntry);
            return existing != null ? existing : newEntry;
        }
        return entry;
    }

    public static final class Entry {
        final String jdbcUrl;
        final String user;
        final String password;
        final String schema;

        // volatile so SMT and NamingStrategy always see the latest reload
        volatile Map<String, String> tableCaseMap = Collections.emptyMap();
        volatile Map<String, Map<String, String>> columnCaseMaps = Collections.emptyMap();
        volatile Map<String, String> flatColumnMap = Collections.emptyMap();

        // Package-private so tests can pin to Long.MAX_VALUE to suppress reloads
        final AtomicLong lastReloadAttempt = new AtomicLong(0);

        Entry(String jdbcUrl, String user, String password, String schema) {
            this.jdbcUrl  = jdbcUrl;
            this.user     = user;
            this.password = password;
            this.schema   = schema;
        }

        void load() {
            log.info("SqlServerSchemaCache: loading metadata from schema '{}' via {}", schema, jdbcUrl);
            final String sql =
                "SELECT t.name AS table_name, c.name AS column_name " +
                "FROM sys.tables t " +
                "INNER JOIN sys.schemas s ON t.schema_id = s.schema_id " +
                "INNER JOIN sys.columns c ON t.object_id = c.object_id " +
                "WHERE s.name = ? AND t.is_ms_shipped = 0 " +
                "ORDER BY t.name, c.column_id";

            Map<String, String> newTableMap = new HashMap<>();
            Map<String, Map<String, String>> newColumnMaps = new HashMap<>();
            Map<String, String> newFlatMap = new HashMap<>();

            DriverManager.setLoginTimeout(30);
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
                            String lower = tableName.toLowerCase(Locale.ROOT);
                            String prev  = newTableMap.put(lower, tableName);
                            if (prev != null && !prev.equals(tableName)) {
                                log.warn("SqlServerSchemaCache: table case collision '{}': '{}' overwritten by '{}'",
                                         lower, prev, tableName);
                            }
                            currentMap = new HashMap<>();
                            newColumnMaps.put(lower, currentMap);
                        }

                        String lower = columnName.toLowerCase(Locale.ROOT);
                        currentMap.put(lower, columnName);

                        String prevFlat = newFlatMap.put(lower, columnName);
                        if (prevFlat != null && !prevFlat.equals(columnName)) {
                            log.warn("SqlServerSchemaCache: flat column case collision for '{}': '{}' overwritten by '{}'",
                                     lower, prevFlat, columnName);
                        }
                    }
                }
            } catch (SQLException e) {
                throw new RuntimeException(
                    "SqlServerSchemaCache: failed to load metadata from SQL Server: " + e.getMessage(), e);
            }

            // Publish atomically — readers see either the old or new complete snapshot
            tableCaseMap   = Collections.unmodifiableMap(newTableMap);
            columnCaseMaps = Collections.unmodifiableMap(newColumnMaps);
            flatColumnMap  = Collections.unmodifiableMap(newFlatMap);

            log.info("SqlServerSchemaCache: cached {} tables, {} total columns for schema '{}'",
                     newTableMap.size(), newFlatMap.size(), schema);
        }

        /**
         * Reloads metadata if a miss is detected and the cooldown has elapsed.
         * Returns true if a reload was performed (caller should retry their lookup).
         */
        public boolean reloadOnMiss(String missingName) {
            long now  = System.currentTimeMillis();
            long last = lastReloadAttempt.get();
            if (now - last < RELOAD_COOLDOWN_MS) {
                log.debug("SqlServerSchemaCache: '{}' not found, reload suppressed (cooldown active)", missingName);
                return false;
            }
            if (!lastReloadAttempt.compareAndSet(last, now)) {
                return false; // another thread won the race
            }
            log.info("SqlServerSchemaCache: '{}' not found in cache — reloading schema metadata", missingName);
            load();
            return true;
        }
    }
}
