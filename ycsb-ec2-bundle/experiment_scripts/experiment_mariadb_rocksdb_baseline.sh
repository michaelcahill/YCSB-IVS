#!/bin/bash

YCSB="bin/ycsb.sh"

# DB names
DB_NAME="ycsb_rdb"
BACKUP_DB_NAME="ycsb_backup_rdb"
UNCHANGE_DB_NAME="ycsb_unchange_rdb"

# Check size of MyRocks file system
DB_PATH="/var/lib/mysql/#rocksdb"

# Path to the RocksDB data directory
DB_URL="jdbc:mysql://localhost:3306/$DB_NAME"
JDBC_PROPERTIES="jdbc-binding/conf/db.properties"
DB_USERNAME="ycsb_user"
DB_PWD="password"

# Change naming parameters here
TYPE="rocksdb"
DIST="uniform" # "uniform" OR "zipfian"
SCALE="light" # "heavy" OR "light"
WORK="spreadrun" # e.g. "mixed", "pure", or "spreadrun"
RUN="1"

# Define the workload file and the log file
WORKLOAD_FILE="../workloads/workloada-extend"
LOG_FILE="./ycsb_${TYPE}_${DIST}_${SCALE}_${WORK}_run${RUN}_results.log"
OUTPUT_CSV="../analysis/${TYPE}_output.csv"

# Define input and output filenames
INPUT_FILE="../analysis/${TYPE}_output.csv"
OUTPUT_FILE="../analysis/Data/Baseline_data/${TYPE}_run${RUN}_${DIST}_${SCALE}_${WORK}.csv"

# Extend phase experiment parameters
extendproportion_extend="0"
readproportion_extend="0"
updateproportion_extend="0"
scanproportion_extend="0"
insertproportion_extend="1"
readmodifywriteproportion_extend="0"
requestdistribution_extend="uniform"

# After extend phase experiment parameters
extendproportion_postextend="0"
readproportion_postextend="0.5"
updateproportion_postextend="0.5"
scanproportion_postextend="0"
insertproportion_postextend="0"
readmodifywriteproportion_postextend="0"
requestdistribution_postextend="uniform"

fieldlengthoriginal="100"
extendoperationcount="10000"

# Create databases
#mysql -u root --password= -e "
#DROP DATABASE IF EXISTS $DB_NAME; 
#CREATE DATABASE $DB_NAME; 
#GRANT ALL PRIVILEGES ON $DB_NAME.* TO '$DB_USERNAME'@'localhost'; 
#FLUSH PRIVILEGES;
#USE $DB_NAME;
#CREATE TABLE usertable ( YCSB_KEY VARCHAR(255) PRIMARY KEY NOT NULL,  
#FIELD0 LONGTEXT, FIELD1 LONGTEXT, FIELD2 LONGTEXT, FIELD3 LONGTEXT, FIELD4 LONGTEXT, 
#FIELD5 LONGTEXT, FIELD6 LONGTEXT, FIELD7 LONGTEXT,FIELD8 LONGTEXT,  FIELD9 LONGTEXT) 
#ENGINE=RocksDB DEFAULT COLLATE=latin1_bin;"

# Flush database contents already existing
mysql -u root --password= -e " 
USE $DB_NAME; 
DELETE FROM usertable;
"

# Function to log and print messages
log() {
    echo "$1" | tee -a $LOG_FILE
}

# Clear the log file and previous backups
> $LOG_FILE

# Function to write results as a csv 
write_result() {
    local first="$1"
    # Remove rows not starting with specific operations and filter specific operations
    filtered_output=$(awk '/^\[(INSERT|READ|UPDATE|SCAN|EXTEND)\]/' "$INPUT_FILE")
    overall_output=$(awk '/^\[(OVERALL)\]/' "$INPUT_FILE")

    if [ "$first" == "TRUE" ]; then   
        # Extract unique second values (except the first one) and create header
        header="Epoch,Phase,Recordcount,Readallfields,Requestdist,Operation,SSTsize,LOGsize,CPU,Memory,sst_files,total_sst_size,lsm_levels,pending_compactions,lsm_memory_usage,Readprop,Updateprop,Scanprop,Insertprop,Extendprop,Runtime(ms),Throughput(ops/sec),$(awk '{print $2}' <<< "$filtered_output" | sed 's/,$//' | uniq | awk '{ORS=","; print}')"
        echo "$header" > "$OUTPUT_FILE"
    fi

    # Iterate through each line
    values_1=""
    values_2=""
    k=1
    p=1
    prev_operation=""
    while IFS= read -r line; do
        # Extract operation and third value
        operation=$(echo "$line" | awk '{print $1}' | sed 's/,$//' | tr -d '[]')
        third_value=$(echo "$line" | awk '{print $3}' | sed 's/,$//')
        r=$((10 * ($epoch - 1) + $run))

        run_specific=()
        # Extract throughput
        while IFS= read -r inner_line; do
            # Extract third value
            tmp=$(echo "$inner_line" | awk '{print $3}' | sed 's/,$//')
            run_specific+=("$tmp")
        done <<< "$overall_output"

        # Append to the values variable
        if [ $k -eq 1 ]; then
            values_1="$r,$phase,$recordcount,$readallfields,$requestdistribution,$operation,$sstsize,$logsize,$cpu,$memory,$sst_files,$total_sst_size,$lsm_levels,$pending_compactions,$lsm_memory_usage,$readproportion,$updateproportion,$scanproportion,$insertproportion,$extendproportion,${run_specific[0]},${run_specific[1]},$third_value"
            k=$((k + 1))
            prev_operation="$operation"
        elif [ $p -eq 1 ] && [ "$prev_operation" == "$operation" ]; then
            values_1="$values_1,$third_value"
        elif [ $p -eq 1 ] && [ "$prev_operation" != "$operation" ]; then
            values_2="$r,$phase,$recordcount,$readallfields,$requestdistribution,$operation,$sstsize,$logsize,$cpu,$memory,$sst_files,$total_sst_size,$lsm_levels,$pending_compactions,$lsm_memory_usage,$readproportion,$updateproportion,$scanproportion,$insertproportion,$extendproportion,${run_specific[0]},${run_specific[1]},$third_value"
            p=$((p + 1))
            prev_operation="$operation"
        else
            values_2="$values_2,$third_value"
        fi
    done <<< "$filtered_output"

    # Print the values to the output file
    echo "$values_1" >> "$OUTPUT_FILE"
    echo "$values_2" >> "$OUTPUT_FILE"

    # Print completion message
    echo "Arrangement completed. Output saved to $OUTPUT_FILE"

}

# Function to close the RocksDB database
close_db() {
    local db_path="$1"
    log "=== Closing RocksDB database at $db_path ==="
    DB=$(basename $db_path)
    if [ -d "$db_path" ]; then
        lsof | grep "$db_path" | awk '{print $2}' | xargs kill -9
        log "Closed RocksDB database at $db_path"
    else
        log "No RocksDB database found at $db_path"
    fi
}

# Global variables for storing MyRocks LSM tree statistics
sst_files=""
total_sst_size=""
lsm_levels=""
pending_compactions=""
lsm_memory_usage=""

# Function to extract MyRocks LSM tree statistics
function extract_myrocks_stats() {
    local db="$1"
    # Run the MyRocks status command and capture the output
    myrocks_status=$(mysql -u root --password= -e "USE $db; SHOW ENGINE ROCKSDB STATUS\G")

    # Extract specific LSM tree values using grep and awk

    # Total number of SST files
    sst_files=$(echo "$myrocks_status" | grep -oP 'Total\s+Sst\s+files\s+in\s+all\s+levels:\s+\K\d+')

    # Size of all SST files
    total_sst_size=$(echo "$myrocks_status" | grep -oP 'Total\s+size\s+of\s+all\s+SST\s+files:\s+\K[0-9]+(?:\.[0-9]+)?\s+[A-Za-z]+')

    # Number of LSM levels
    lsm_levels=$(echo "$myrocks_status" | grep -oP 'Number\s+of\s+LSM\s+tree\s+levels:\s+\K\d+')

    # Pending compactions
    pending_compactions=$(echo "$myrocks_status" | grep -oP 'Pending\s+compaction\s+bytes:\s+\K[0-9]+(?:\.[0-9]+)?\s+[A-Za-z]+')

    # Memory usage for LSM
    lsm_memory_usage=$(echo "$myrocks_status" | grep -oP 'Block\s+cache\s+usage:\s+\K[0-9]+(?:\.[0-9]+)?\s+[A-Za-z]+')

}

# Step 1: Delete the ycsb database on MongoDB if any
log "=== Deleting the ycsb database on MongoDB, if any ==="
#rm -rf "$DB_PATH"
#echo "RocksDB database at $DB_PATH has been deleted."

# Execute the load phase
log "=== Executing the load phase ==="
phase="load"
$YCSB load jdbc -s -P $WORKLOAD_FILE -P $JDBC_PROPERTIES -p db.url="$DB_URL" -p db.user="$DB_USERNAME" -p db.passwd="$DB_PWD" > $OUTPUT_CSV 
sstsize=$(sudo DB_PATH="$DB_PATH" bash -c 'du -sck "$DB_PATH"/*.sst | tail -n 1 | cut -f1')
logsize=$(sudo DB_PATH="$DB_PATH" bash -c 'du -sck "$DB_PATH"/*.log | tail -n 1 | cut -f1') 
cpu=$(ps -p $(pgrep -x mariadbd) -o %cpu | grep -o "[0-9.]*")
memory=$(ps -p $(pgrep -x mariadbd) -o %mem | grep -o "[0-9.]*") 
extract_myrocks_stats $DB_NAME
write_result "TRUE"

# Experiment parameters
for epoch in $(seq 1 10); do
    for run in $(seq 1 10); do

        # Setting parameter values for extend phase
        log "=== Setting parameter values for extend phase ==="
        perl -i -p -e "s/^extendproportion=.*/extendproportion=$extendproportion_extend/" $WORKLOAD_FILE
        perl -i -p -e "s/^readproportion=.*/readproportion=$readproportion_extend/" $WORKLOAD_FILE
        perl -i -p -e "s/^updateproportion=.*/updateproportion=$updateproportion_extend/" $WORKLOAD_FILE
        perl -i -p -e "s/^scanproportion=.*/scanproportion=$scanproportion_extend/" $WORKLOAD_FILE
        perl -i -p -e "s/^insertproportion=.*/insertproportion=$insertproportion_extend/" $WORKLOAD_FILE
        perl -i -p -e "s/^readmodifywriteproportion=.*/readmodifywriteproportion=$readmodifywriteproportion_extend/" $WORKLOAD_FILE
        perl -i -p -e "s/^requestdistribution=.*/requestdistribution=$requestdistribution_extend/" $WORKLOAD_FILE
        source "$WORKLOAD_FILE"

        # Extract the recordcount and operationcount from the workload file
        operationcount=$(grep -E '^operationcount=' "$WORKLOAD_FILE" | cut -d'=' -f2)
        recordcount=$(grep -E '^recordcount=' "$WORKLOAD_FILE" | cut -d'=' -f2)
        
        # Compute the new record number to be added
        updatedoperationcount=$(echo "($extendoperationcount / 10)" | bc)

        # Change operation count for insert mode
        perl -i -p -e "s/^operationcount=.*/operationcount=$updatedoperationcount/" $WORKLOAD_FILE

        $YCSB run jdbc -s -P $WORKLOAD_FILE -P $JDBC_PROPERTIES -p db.url="$DB_URL" -p db.user="$DB_USERNAME" -p db.passwd="$DB_PWD" > $OUTPUT_CSV

        # Setting parameter values for run phase
        log "=== Setting parameter values for run phase ==="
        perl -i -p -e "s/^extendproportion=.*/extendproportion=$extendproportion_postextend/" $WORKLOAD_FILE
        perl -i -p -e "s/^readproportion=.*/readproportion=$readproportion_postextend/" $WORKLOAD_FILE
        perl -i -p -e "s/^updateproportion=.*/updateproportion=$updateproportion_postextend/" $WORKLOAD_FILE
        perl -i -p -e "s/^scanproportion=.*/scanproportion=$scanproportion_postextend/" $WORKLOAD_FILE
        perl -i -p -e "s/^insertproportion=.*/insertproportion=$insertproportion_postextend/" $WORKLOAD_FILE
        perl -i -p -e "s/^readmodifywriteproportion=.*/readmodifywriteproportion=$readmodifywriteproportion_postextend/" $WORKLOAD_FILE
        perl -i -p -e "s/^requestdistribution=.*/requestdistribution=$requestdistribution_postextend/" $WORKLOAD_FILE
        source "$WORKLOAD_FILE"

        # Compute new record count
        updatedrecordcount=$(echo "$recordcount + ($extendoperationcount / 10)" | bc)

        # Setting parameter values for load phase
        log "=== Setting parameter values for run phase ==="
        perl -i -p -e "s/^recordcount=.*/recordcount=$updatedrecordcount/" $WORKLOAD_FILE
        # Change operation count for insert mode
        perl -i -p -e "s/^operationcount=.*/operationcount=$operationcount/" $WORKLOAD_FILE
        source "$WORKLOAD_FILE" 

        # Execute the run phase
        phase="spread-run"
        $YCSB run jdbc -s -P $WORKLOAD_FILE -P $JDBC_PROPERTIES -p db.url="$DB_URL" -p db.user="$DB_USERNAME" -p db.passwd="$DB_PWD" > $OUTPUT_CSV
        sstsize=$(sudo DB_PATH="$DB_PATH" bash -c 'du -sck "$DB_PATH"/*.sst | tail -n 1 | cut -f1')
        logsize=$(sudo DB_PATH="$DB_PATH" bash -c 'du -sck "$DB_PATH"/*.log | tail -n 1 | cut -f1') 
        cpu=$(ps -p $(pgrep -x mariadbd) -o %cpu | grep -o "[0-9.]*")
        memory=$(ps -p $(pgrep -x mariadbd) -o %mem | grep -o "[0-9.]*") 
        extract_myrocks_stats $DB_NAME
        write_result "FALSE"

    done
done

# Delete intermediate temp files
rm -rf $LOG_FILE
rm -rf $OUTPUT_CSV

log "=== All steps completed. Results are logged in $LOG_FILE ==="
