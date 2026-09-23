# YCSB-EC2-Bundle

This bundle contains all necessary files and directories to run YCSB-IVS experiments on EC2 or similar environments.

## Contents

### Experiment Scripts
- **experiment_scripts/**: The experiment harness. One runner —
  `./experiment.sh <backend> [options]` — with one module per backend in
  `lib/backends/`, shared engine code in `lib/`, parsed configuration in `conf/`,
  deployment tooling in `tools/` (`deploy.sh`, `bundle.sh`) and the test suite in
  `tests/`. Backends: PostgreSQL (text-array, jsonb-array, row, PostgreNoSQL),
  MariaDB (InnoDB, RocksDB), MongoDB, Neo4j, Couchbase; two phase sequences
  (`mainline` and `--mode baseline`). See `experiment_scripts/README.md` for the runbook.

### Core YCSB Components
- **bin/**: YCSB execution scripts (`ycsb.sh`) and bindings configuration
- **core/**: Core YCSB functionality (required for execution)
- **workloads/**: Workload definition files, including `workloada-extend`

### Database Bindings
- **jdbc/**: JDBC binding source code (for PostgreSQL, MariaDB)
- **jdbc-array/**: JDBC binding variant that stores each field as a PostgreSQL `TEXT[]` array column
- **jdbc-array-json/**: JDBC binding variant that stores each field as a `JSONB` column
- **jdbc-binding/**: JDBC binding configuration and libraries
  - `conf/postgres.properties`: PostgreSQL configuration
  - `conf/db.properties`: General database configuration
  - `lib/`: JDBC driver libraries
- **postgrenosql/**: PostgreNoSQL binding source code (PostgreSQL as a JSONB document store)
  - Stores each record as a single JSONB document: `usertable (YCSB_KEY VARCHAR(255) PRIMARY KEY, YCSB_VALUE JSONB)`
  - `conf/postgrenosql.properties`: connection configuration (`postgrenosql.url`, `postgrenosql.user`, `postgrenosql.passwd`, `postgrenosql.autocommit`)
  - Registered in `bin/bindings.properties` as `postgrenosql:site.ycsb.postgrenosql.PostgreNoSQLDBClient`
  - Built as the `postgrenosql-binding` Maven module (listed in the root `pom.xml`)
- **neo4j/**: Neo4j database binding
- **mongodb/**: MongoDB database binding

### Build Configuration
- **pom.xml**: Root Maven project file
- **binding-parent/**: Parent POM for bindings
- **LICENSE.txt** and **NOTICE.txt**: License files

### Output Directories
Experiment outputs are written under `analysis/` at runtime (this directory is git-ignored and is **not** included in the bundle):
- **analysis/Data/Baseline_data/**: Baseline experiment results
- **analysis/Data/Value_size_data/**: Value size distribution data
- **analysis/Data/Workload_data/**: Workload execution results

Most scripts do not create these directories themselves, so on a fresh checkout create them first:
```bash
mkdir -p analysis/Data/Baseline_data analysis/Data/Value_size_data analysis/Data/Workload_data
```

## Usage

1. **Build the project** (if needed):
   ```bash
   mvn clean package
   ```

2. **Run an experiment** (from the bundle root, i.e., the directory containing this README):
   ```bash
   cd experiment_scripts
   ./experiment.sh postgresql_row            # full phase sequence
   ./experiment.sh postgresql_row --mode baseline   # fixed value sizes, no comparison phases
   ```

   Equivalently, from the parent directory of the bundle:
   ```bash
   cd ycsb-ec2-bundle/experiment_scripts
   ./experiment.sh postgresql_row
   ```

   The runner `cd`s into its own directory at startup, so it also works when invoked with
   a full path from anywhere. Every backend — including the PostgreNoSQL document store
   (`./experiment.sh postgrenosql`, schema `YCSB_KEY` + `YCSB_VALUE JSONB`) — is selected
   by name; schemas are created automatically, and connection parameters come from
   `experiment_scripts/conf/db.<backend>.env` (copy the `.example`; never hardcode
   credentials in scripts).

3. **View results**:
   Each run writes to its own directory under `analysis/experiments/ycsb_<name>/`
   (`data/workload_data/<name>.csv` is the analysis input). See
   `experiment_scripts/README.md` §Output Layout.

## Notes

- The runner resolves its own location at startup (`cd "$SCRIPT_DIR"`), so relative paths
  like `../bin/ycsb.sh` and `../workloads/workloada-extend` work regardless of the invocation directory
- Workload files under `workloads/` are read-only templates; every run generates its own
  immutable copies under the experiment directory's `workloads/`
- Ensure database servers are running and configured before executing experiments;
  `./experiment.sh <backend> --check` verifies one backend without benchmarking
- Database connection parameters live in `experiment_scripts/conf/db.<backend>.env`
  (gitignored, parsed not executed); run `tools/deploy.sh` to ship the harness to an EC2 host

## Requirements

- Java Development Kit (JDK)
- Maven (for building from source, if target/ directories don't exist)
- Database-specific clients:
  - PostgreSQL: `psql`, `dropdb`, `createdb`, `pg_dump` commands
  - Neo4j: `cypher-shell` command
  - MongoDB: `mongosh`, `mongodump`, `mongorestore` commands
  - MariaDB: `mysql` command
- Host tools used by the experiment scripts: `perl`, `bc`, `awk`, `ps`, `comm`, `sort`

