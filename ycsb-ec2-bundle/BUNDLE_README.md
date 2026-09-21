# YCSB-EC2-Bundle

This bundle contains all necessary files and directories to run YCSB-IVS experiments on EC2 or similar environments.

## Contents

### Experiment Scripts
- **experiment_scripts/**: Contains all experiment bash scripts for running workloads
  - PostgreSQL experiments (baseline and extended)
  - Neo4j experiments (baseline and extended)
  - MongoDB experiments (baseline and extended)
  - MariaDB experiments (InnoDB and RocksDB, baseline and extended)
  - Sample experiments

### Core YCSB Components
- **bin/**: YCSB execution scripts (`ycsb.sh`) and bindings configuration
- **core/**: Core YCSB functionality (required for execution)
- **workloads/**: Workload definition files, including `workloada-extend`

### Database Bindings
- **jdbc/**: JDBC binding source code (for PostgreSQL, MariaDB)
- **jdbc-binding/**: JDBC binding configuration and libraries
  - `conf/postgres.properties`: PostgreSQL configuration
  - `conf/db.properties`: General database configuration
  - `lib/`: JDBC driver libraries
- **neo4j/**: Neo4j database binding
- **mongodb/**: MongoDB database binding

### Build Configuration
- **pom.xml**: Root Maven project file
- **binding-parent/**: Parent POM for bindings
- **LICENSE.txt** and **NOTICE.txt**: License files

### Output Directories
- **analysis/Data/**: Directory structure for experiment outputs
  - `Baseline_data/`: Baseline experiment results
  - `Value_size_data/`: Value size distribution data
  - `Workload_data/`: Workload execution results

## Usage

1. **Build the project** (if needed):
   ```bash
   mvn clean package
   ```

2. **Run an experiment**:
   ```bash
   cd experiment_scripts
   ./experiment_postgresql_baseline.sh
   ```

   Or run from the bundle root:
   ```bash
   cd ycsb-ec2-bundle/experiment_scripts
   ./experiment_postgresql_baseline.sh
   ```

3. **View results**:
   Results will be written to `analysis/Data/` subdirectories as configured in each script.

## Notes

- The scripts use relative paths (e.g., `../bin/ycsb.sh`, `../workloads/workloada-extend`)
- Scripts should be executed from the `experiment_scripts/` directory
- Ensure database servers are running and configured before executing experiments
- Database connection parameters should be updated in each script before execution

## Requirements

- Java Development Kit (JDK)
- Maven (for building from source, if target/ directories don't exist)
- Database-specific clients:
  - PostgreSQL: `psql`, `dropdb`, `createdb` commands
  - Neo4j: `cypher-shell` command
  - MongoDB: `mongosh`, `mongodump`, `mongorestore` commands
  - MariaDB: `mysql` command

