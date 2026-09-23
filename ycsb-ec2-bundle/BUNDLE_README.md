# YCSB-EC2-Bundle

This bundle contains all necessary files and directories to run YCSB-IVS experiments on EC2 or similar environments.

## Contents

### Experiment Scripts
- **experiment_scripts/**: Contains all experiment bash scripts for running workloads
  - PostgreSQL experiments (baseline and extended)
  - PostgreSQL array/JSONB-column experiments (`experiment_postgresql_array*.sh`)
  - PostgreNoSQL JSONB document-store experiment (`experiment_postgrenosql.sh`)
  - Neo4j experiments (baseline and extended)
  - Couchbase experiments (baseline and extended)
  - MongoDB experiments (baseline and extended)
  - MariaDB experiments (InnoDB and RocksDB, baseline and extended)
  - Sample experiments

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

   (The one `experiment_<backend>.sh` per backend is a compatibility shim for this single
   runner; it disappears with REFACTOR_PLAN.md step 8c. This whole file is rewritten in
   step 7.)

   The scripts `cd` into their own directory at startup, so they also work when invoked
   with a full path from anywhere.

   The PostgreNoSQL document-store experiment works the same way:
   ```bash
   cd experiment_scripts
   ./experiment_postgrenosql.sh
   ```

   It creates the JSONB document schema (`YCSB_KEY` + `YCSB_VALUE JSONB`) automatically and runs
   YCSB with the `postgrenosql` binding. Value sizes are measured as the serialized JSONB document
   size (`octet_length(ycsb_value::text)`), which includes per-field key/quote overhead.

3. **View results**:
   Results will be written to `analysis/Data/` subdirectories as configured in each script.

## Notes

- The scripts resolve their own location at startup (`cd "$SCRIPT_DIR"`), so relative paths
  like `../bin/ycsb.sh` and `../workloads/workloada-extend` work regardless of the invocation directory
- `experiment_postgrenosql.sh` is a variant of `experiment_postgresql.sh` for the `postgrenosql`
  binding: same experiment flow (extend/run/reference/clean-run/avg-run phases, metrics, key-size
  tracking), but with the JSONB document schema instead of one column per field. Note that the
  extend phase requires an `extend()` implementation in the binding; without it, all EXTEND
  operations fail and the script aborts after the extend phase.
- Ensure database servers are running and configured before executing experiments
- Database connection parameters should be updated in each script before execution

## Requirements

- Java Development Kit (JDK)
- Maven (for building from source, if target/ directories don't exist)
- Database-specific clients:
  - PostgreSQL: `psql`, `dropdb`, `createdb`, `pg_dump` commands
  - Neo4j: `cypher-shell` command
  - MongoDB: `mongosh`, `mongodump`, `mongorestore` commands
  - MariaDB: `mysql` command
- Host tools used by the experiment scripts: `perl`, `bc`, `awk`, `ps`, `comm`, `sort`

