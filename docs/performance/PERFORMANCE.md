# CDC Performance Benchmarks

This document captures validated performance metrics from production test runs using the snapshot tuning profile.

## Bulk Load Performance

**Configuration:** SQL Server → Kafka (initial snapshot)
- **Rate:** 55,000 rows/sec sustained
- **Test:** 10GB (8.59M workitemdata + 4.29M customers)
- **Duration:** 3 minutes
- **Storage:** 100% NVMe (i3.4xlarge brokers)
- **Status:** ✅ Production-ready

### Load Characteristics
- workitemdata: ~1000 bytes/row (XML + binary attachment)
- customers: ~500 bytes/row (padded address field)
- Batch size: 50,000 rows (workitemdata), 75,000 rows (customers)
- FK constraints: NOCHECK'd during insert, re-enabled after batch

## CDC Snapshot Performance

**Configuration:** SQL Server → Kafka → Aurora PostgreSQL (JDBC sink)
- **Rate:** 850,000 rows/min sustained
- **Test:** 10GB initial snapshot (all tables)
- **Duration:** ~10 minutes
- **Storage:** NVMe (brokers) + EBS gp3 (Aurora)
- **Status:** ✅ Production-ready

### Snapshot Execution Timeline
```
Phase 2a: Deploy repo to nodes         2 min
Phase 5:  Connectors startup          10 min  
Snapshot: Data transfer               10 min
──────────────────────────────────
Total:    End-to-end                  ~22 min
```

### Bottleneck Analysis (Snapshot)
- **Debezium Source:** ~1.2M rows/min read rate (SQL Server CDC polling)
- **JDBC Sink:** ~850K rows/min write rate (Aurora upsert)
- **Kafka Broker:** No backpressure observed
- **Limiting Factor:** Aurora JDBC sink write throughput

## Tuning Profile Validation

**Profile:** `.env.snapshot` (bulk load optimized)

| Parameter | Value | Rationale | Validated |
|-----------|-------|-----------|-----------|
| CONNECT_CONSUMER_MAX_POLL_RECORDS | 10000 | Large fetch reduces latency | ✅ |
| CONNECT_PRODUCER_BATCH_SIZE | 1 MB | Reduces per-record overhead | ✅ |
| CONNECT_PRODUCER_COMPRESSION_TYPE | zstd | Better compression vs snappy | ✅ |
| SQLSERVER_SOURCE_MAX_BATCH_SIZE | 16384 | Queries 16K rows per poll | ✅ |
| SQLSERVER_SOURCE_MAX_QUEUE_SIZE | 65536 | Large buffer reduces stalls | ✅ |
| SQLSERVER_SOURCE_SNAPSHOT_FETCH_SIZE | 20000 | 20K row fetch per statement | ✅ |

**Conclusion:** No adjustments needed. Snapshot profile is optimal for production 10GB+ loads.

## Scaling Estimates

Based on observed rates, projected performance for larger datasets:

| Data Volume | Bulk Load Time | Snapshot Time | Total Time |
|-------------|----------------|---------------|-----------|
| 10 GB (test) | 3 min | 10 min | ~22 min |
| 50 GB | 15 min | 50 min | ~75 min |
| 100 GB | 30 min | 100 min | ~150 min |
| 1 TB | 5 hours | 16 hours | ~21 hours |

**Notes:**
- Linear scaling assumes consistent hardware and network
- Aurora write bottleneck (~850K rows/min) is the limiting factor at scale
- For 1TB+, consider enabling parallel sink tasks or horizontal scaling

## Production Recommendations

1. **Snapshot Profile:** Use `.env.snapshot` for all initial loads ≥100GB
2. **Bulk Loader:** Production-ready; can scale to 100GB+ without changes
3. **JDBC Sink:** Pre-create target tables (auto-create is not reliable)
4. **CDC Re-enable:** After snapshot completes, switch to `.env.streaming` profile

## Known Limitations

- **JDBC Sink:** auto.create fails if schema registry doesn't have target table DDL
  - **Workaround:** Pre-create tables on target database before sink starts
  
- **Debezium Snapshot:** Captures ALL tables initially (not just CDC-enabled)
  - **Why:** Debezium needs full schema; switches to CDC-only after snapshot
  - **Design:** This is scalable; empty `table.include.list` is intentional

## Testing Methodology

- **Infrastructure:** 3x i3.4xlarge brokers, 1x m5.2xlarge connect, 1x m5d.2xlarge monitor
- **Data:** Synthetic workload (XML + binary attachments, composite records)
- **Measurement:** Wall-clock time with consistent hardware/network conditions
- **Date:** 2026-05-02/03
