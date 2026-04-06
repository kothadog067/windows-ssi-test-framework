# dd-jvm-skiplist-kafka

**Negative test**: Verifies that Apache Kafka is NOT instrumented by SSI. Kafka (`kafka.Kafka` main class) is listed in `workload_selection_hardcoded.json` in the ddinjector source — a JVM skip list that prevents instrumentation of known infrastructure workloads.

## JVM Skip List (from workload_selection_hardcoded.json)

The ddinjector checks the JVM startup arguments (main class, classpath) to detect skip-listed workloads:

| Workload | Main Class Pattern | Why Skipped |
|----------|-------------------|-------------|
| **Apache Kafka** | `kafka.Kafka` | Message broker — instrumentation causes issues |
| Apache ZooKeeper | `org.apache.zookeeper.*` | Coordination service |
| Apache Cassandra | `org.apache.cassandra.*` | Database |
| Elasticsearch | `org.elasticsearch.*` | Search engine |
| Apache Hadoop | `org.apache.hadoop.*` | Distributed compute |
| HBase | `org.apache.hbase.*` | Database |

## Services Started

| Service | Purpose | Port |
|---------|---------|------|
| ZooKeeperSvc | Kafka dependency | 2181 |
| KafkaBrokerSvc | Apache Kafka broker (main test target) | 9092 |

## What This Tests

- **JVM skip list enforcement**: `java.exe` running `kafka.Kafka` does NOT have `ddinjector_x64.dll` loaded
- **Per-PID check**: Each `java.exe` process is inspected individually by command line
- **Kafka health**: Port 9092 is listening (confirms Kafka actually started)

## Pass Condition

`ddinjector_x64.dll` is **absent** from `java.exe` processes running Kafka. This is the inverse of the normal injection test.

## Quick Start

```powershell
.\scripts\setup.ps1 -DDApiKey "your_key" -InstallAgent
.\scripts\verify.ps1 -TargetHost localhost
.\scripts\teardown.ps1
```
