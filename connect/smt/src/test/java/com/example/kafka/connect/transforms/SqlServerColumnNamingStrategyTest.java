package com.example.kafka.connect.transforms;

import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.DisplayName;
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
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.mockStatic;
import static org.mockito.Mockito.when;

@ExtendWith(MockitoExtension.class)
class SqlServerColumnNamingStrategyTest {

    private SqlServerColumnNamingStrategy strategy;

    @Mock private Connection conn;
    @Mock private PreparedStatement ps;
    @Mock private ResultSet rs;

    @BeforeEach
    void setUp() {
        strategy = new SqlServerColumnNamingStrategy();
        // Clear shared static cache between tests so each test gets a fresh entry
        SqlServerSchemaCache.CACHE.clear();
    }

    private Map<String, String> configProps() {
        Map<String, String> props = new HashMap<>();
        props.put(SqlServerColumnNamingStrategy.JDBC_URL_KEY,
                  "jdbc:sqlserver://localhost:1433;databaseName=testdb;encrypt=false");
        props.put(SqlServerColumnNamingStrategy.JDBC_USER_KEY, "sa");
        props.put(SqlServerColumnNamingStrategy.JDBC_PASS_KEY, "Password123!");
        props.put(SqlServerColumnNamingStrategy.SCHEMA_KEY, "dbo");
        return props;
    }

    @Test
    @DisplayName("resolveColumnName maps lowercase to camelCase")
    void resolvesCamelCase() throws Exception {
        when(conn.prepareStatement(anyString())).thenReturn(ps);
        when(ps.executeQuery()).thenReturn(rs);
        when(rs.next()).thenReturn(true, true, true, false);
        when(rs.getString("table_name")).thenReturn("workItemData", "workItemData", "workItemData");
        when(rs.getString("column_name")).thenReturn("workItemId", "dataXml", "createdAt");

        try (MockedStatic<DriverManager> dm = mockStatic(DriverManager.class)) {
            dm.when(() -> DriverManager.getConnection(anyString(), anyString(), anyString()))
              .thenReturn(conn);
            strategy.configure(configProps());
        }

        assertEquals("workItemId", strategy.resolveColumnName("workitemid"));
        assertEquals("dataXml", strategy.resolveColumnName("dataxml"));
        assertEquals("createdAt", strategy.resolveColumnName("createdat"));
    }

    @Test
    @DisplayName("resolveColumnName returns original when no mapping exists")
    void returnsOriginalWhenNoMapping() throws Exception {
        when(conn.prepareStatement(anyString())).thenReturn(ps);
        when(ps.executeQuery()).thenReturn(rs);
        when(rs.next()).thenReturn(false);

        try (MockedStatic<DriverManager> dm = mockStatic(DriverManager.class)) {
            dm.when(() -> DriverManager.getConnection(anyString(), anyString(), anyString()))
              .thenReturn(conn);
            strategy.configure(configProps());
        }

        // Suppress reload-on-miss — no SQL Server in test env
        strategy.cacheEntry.lastReloadAttempt.set(Long.MAX_VALUE - SqlServerSchemaCache.RELOAD_COOLDOWN_MS);
        assertEquals("unknownfield", strategy.resolveColumnName("unknownfield"));
    }

    @Test
    @DisplayName("resolveColumnName handles null input")
    void handlesNull() {
        assertNull(strategy.resolveColumnName(null));
    }

    @Test
    @DisplayName("configure fails fast when SQL Server is unreachable")
    void failsFastOnConnectionError() {
        SQLException sqlEx = new SQLException("Connection refused");
        try (MockedStatic<DriverManager> dm = mockStatic(DriverManager.class)) {
            dm.when(() -> DriverManager.getConnection(anyString(), anyString(), anyString()))
              .thenThrow(sqlEx);
            assertThrows(RuntimeException.class, () -> strategy.configure(configProps()));
        }
    }

    @Test
    @DisplayName("configure warns and returns when JDBC config is missing")
    void skipsWhenConfigMissing() {
        Map<String, String> props = new HashMap<>();
        // No JDBC config — should not throw
        strategy.configure(props);
        // With empty map, resolve should pass through
        assertEquals("workitemid", strategy.resolveColumnName("workitemid"));
    }
}
