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
BACKUP_URL="jdbc:mysql://localhost:3306/$BACKUP_DB_NAME"
BACKUP_FILE="./ycsb_dump.sql"
UNCHANGE_DB_URL="jdbc:mysql://localhost:3306/$UNCHANGE_DB_NAME"

# Change naming parameters here
TYPE="rocksdb"
DIST="uniform" # "uniform" OR "zipfian"
SCALE="light" # "heavy" OR "light"
WORK="pure" # e.g. "mixed", "pure", or "spreadrun"
RUN="1"

# Define the workload file and the log file
WORKLOAD_FILE="../workloads/workloada-extend"
LOG_FILE="./ycsb_${TYPE}_${DIST}_${SCALE}_${WORK}_run${RUN}_results.log"
OUTPUT_CSV="../analysis/${TYPE}_output.csv"

# Define input and output filenames
INPUT_FILE="../analysis/${TYPE}_output.csv"
OUTPUT_FILE="../analysis/Data/Workload_data/${TYPE}_run${RUN}_${DIST}_${SCALE}_${WORK}.csv"

# Key size gathering
KEY_SIZE_LOG="key_sizes_${TYPE}_${DIST}_${SCALE}_${WORK}_run${RUN}.csv"
KEY_SIZE_FILE_AFTER_EXTEND="../analysis/Data/Value_size_data/value_sizes_${TYPE}_run${RUN}_${DIST}_${SCALE}_before_${WORK}.csv"
KEY_SIZE_FILE_AFTER_RUN="../analysis/Data/Value_size_data/value_sizes_${TYPE}_run${RUN}_${DIST}_${SCALE}_after_${WORK}.csv"
HISTOGRAM_FILE="histogram.txt"

# Extend phase experiment parameters
extendproportion_extend="1"
readproportion_extend="0"
updateproportion_extend="0"
scanproportion_extend="0"
insertproportion_extend="0"
requestdistribution_extend="uniform"

# After extend phase experiment parameters
extendproportion_postextend="0"
readproportion_postextend="1"
updateproportion_postextend="0"
scanproportion_postextend="0"
insertproportion_postextend="0"
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
USE $BACKUP_DB_NAME; 
DELETE FROM usertable;
USE $UNCHANGE_DB_NAME; 
DELETE FROM usertable;"

# Function to log and print messages
log() {
    echo "$1" | tee -a $LOG_FILE
}

# Clear the log file and previous backups
> $LOG_FILE
rm -rf $BACKUP_DIR
rm -rf $KEY_SIZE_FILE

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

# Function to append values for the first iteration
append_first_iteration() {
    local key_size_log="$1"
    local key_size_file="$2"

    echo "Appending first iteration..."
    awk -F, 'NR==1 {next} {print $1 "," $2}' "$key_size_log" >> "$key_size_file"
    echo "First iteration: Appended values from $key_size_log to $key_size_file"
}

# Function to append sizes for subsequent iterations
append_subsequent_iterations() {
    local key_size_log="$1"
    local key_size_file="$2"

    echo "Appending subsequent iteration $iteration..."
    awk -F, -v iter="$iteration" '
        NR==FNR {if (NR > 1) {key_sizes[$1]=$2;} next}  # Read key_sizes from log
        FNR==1 {print $0 ",Run" iter; next}             # Add new run column in the header
        ($1 in key_sizes) {print $0 "," key_sizes[$1]}  # Append size for existing key
        !($1 in key_sizes) {print $0 ",0"}              # If key is not found, append 0
    ' "$key_size_log" "$key_size_file" > temp.csv

    mv temp.csv "$key_size_file"  # Overwrite the file with updated content
    echo "Iteration $iteration: Appended new size values from $key_size_log to $key_size_file"
}

get_key_sizes() {
    local key_size_log="$1"
    local histogram_file="$2"

    echo "Generating histogram from key size log: $key_size_log"

    awk -F, '
        BEGIN {
            block = 100
            OFS = "\t"
        }
        NR == 1 { next }  # Skip header
        {
            size = $2 + 0
            bucket = int(size / (block * 10 ))   #Converting value length to field length as there are 10 fields
            histogram[bucket]++
            if (bucket > max_bucket) max_bucket = bucket
        }
        END {
            print "BlockSize", block > "'"$histogram_file"'"
            for (i = 0; i <= max_bucket; i++) {
                count = (i in histogram) ? histogram[i] : 0
                print i, count >> "'"$histogram_file"'"
            }
        }
    ' "$key_size_log"

    echo "Histogram written to $histogram_file (BlockSize = 100)"
}

delete_new_keys() {
  local db_name="$1"            # Required: name of the database
  local user="${2:-root}"       # Optional: MySQL username (default: root)
  local password="${3:-}"       # Optional: MySQL password (default: empty)
  local table="${4:-usertable}" # Optional: table name (default: usertable)
  local key_column="${5:-YCSB_KEY}" # Optional: primary key column (default: YCSB_KEY)

  local file_before="keys.txt"
  local file_after="keys_after_run.txt"
  local file_to_delete="keys_to_delete.txt"

  if [[ -z "$db_name" ]]; then
    echo "Usage: delete_new_keys <db_name> [user] [password] [table] [key_column]"
    return 1
  fi

  # Sort the key files
  sort "$file_before" > keys_sorted.txt
  sort "$file_after" > keys_after_sorted.txt

  # Find keys that are only in keys_after_run.txt
  comm -13 keys_sorted.txt keys_after_sorted.txt > "$file_to_delete"

  echo "Deleting $(wc -l < "$file_to_delete") new keys from '$table' in database '$db_name'..."

  # Run DELETE statements
  while read -r key; do
    echo "DELETE FROM $table WHERE $key_column='$key';"
  done < "$file_to_delete" | mysql -u "$user" --password="$password" -D "$db_name"

  echo "✅ Deletion complete."
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

# Load unchange value size (reference) DB
$YCSB load jdbc -s -P $WORKLOAD_FILE -P $JDBC_PROPERTIES -p db.url="$UNCHANGE_DB_URL" -p db.user="$DB_USERNAME" -p db.passwd="$DB_PWD" > $OUTPUT_CSV

# Experiment parameters
for epoch in $(seq 1 10); do
    for run in $(seq 1 10); do

        # Record operation count from workload configuration file
        opscount=$(grep -E '^operationcount=' "$WORKLOAD_FILE" | cut -d'=' -f2)
        
        # Setting parameter values for extend phase
        log "=== Setting parameter values for extend phase ==="
        perl -i -p -e "s/^extendproportion=.*/extendproportion=$extendproportion_extend/" $WORKLOAD_FILE
        perl -i -p -e "s/^readproportion=.*/readproportion=$readproportion_extend/" $WORKLOAD_FILE
        perl -i -p -e "s/^updateproportion=.*/updateproportion=$updateproportion_extend/" $WORKLOAD_FILE
        perl -i -p -e "s/^scanproportion=.*/scanproportion=$scanproportion_extend/" $WORKLOAD_FILE
        perl -i -p -e "s/^insertproportion=.*/insertproportion=$insertproportion_extend/" $WORKLOAD_FILE
        perl -i -p -e "s/^readmodifywriteproportion=.*/readmodifywriteproportion=$readmodifywriteproportion_extend/" $WORKLOAD_FILE
        perl -i -p -e "s/^requestdistribution=.*/requestdistribution=$requestdistribution_extend/" $WORKLOAD_FILE
        perl -i -p -e "s/^operationcount=.*/operationcount=$extendoperationcount/" $WORKLOAD_FILE
        source "$WORKLOAD_FILE"

        # Execute the run phase
        log "=== Executing the run phase with extendproportion=0.2 and other proportions=0 ==="
        phase="extend"
        $YCSB run jdbc -s -P $WORKLOAD_FILE -P $JDBC_PROPERTIES -p db.url="$DB_URL" -p db.user="$DB_USERNAME" -p db.passwd="$DB_PWD" > $OUTPUT_CSV
        sstsize=$(sudo DB_PATH="$DB_PATH" bash -c 'du -sck "$DB_PATH"/*.sst | tail -n 1 | cut -f1')
        logsize=$(sudo DB_PATH="$DB_PATH" bash -c 'du -sck "$DB_PATH"/*.log | tail -n 1 | cut -f1')  
        cpu=$(ps -p $(pgrep -x mariadbd) -o %cpu | grep -o "[0-9.]*")
        memory=$(ps -p $(pgrep -x mariadbd) -o %mem | grep -o "[0-9.]*") 
        extract_myrocks_stats $DB_NAME
        write_result "FALSE"

        # Key Sizes
        echo "Size computation started"
        mysql -u root --password= -e " 
        USE $DB_NAME; 
        SELECT YCSB_KEY, 
            (LENGTHB(FIELD0) + LENGTHB(FIELD1) + LENGTHB(FIELD2) + LENGTHB(FIELD3) + 
            LENGTHB(FIELD4) + LENGTHB(FIELD5) + LENGTHB(FIELD6) + LENGTHB(FIELD7) + 
            LENGTHB(FIELD8) + LENGTHB(FIELD9)) AS Size FROM usertable;" | sed 's/\t/,/g' > $KEY_SIZE_LOG

        get_key_sizes $KEY_SIZE_LOG $HISTOGRAM_FILE

        # Check if the output file exists, if not, create it with headers
        iteration=$((10*($epoch-1)+$run))

        if [ $iteration -eq 5 ]; then
            exit
        fi

        if [[ ! -f "$KEY_SIZE_FILE_AFTER_EXTEND" ]]; then
            # Add header row (Key, Run1, Run2, ...)
            echo "Key,Run$iteration" > "$KEY_SIZE_FILE_AFTER_EXTEND"
        fi

        # If it's the first iteration, append keys and sizes for the first run
        if [[ "$iteration" -eq 1 ]]; then
            append_first_iteration $KEY_SIZE_LOG $KEY_SIZE_FILE_AFTER_EXTEND
        else
            append_subsequent_iterations $KEY_SIZE_LOG $KEY_SIZE_FILE_AFTER_EXTEND
        fi

        # Setting parameter values for run phase
        log "=== Setting parameter values for run phase ==="
        perl -i -p -e "s/^extendproportion=.*/extendproportion=$extendproportion_postextend/" $WORKLOAD_FILE
        perl -i -p -e "s/^readproportion=.*/readproportion=$readproportion_postextend/" $WORKLOAD_FILE
        perl -i -p -e "s/^updateproportion=.*/updateproportion=$updateproportion_postextend/" $WORKLOAD_FILE
        perl -i -p -e "s/^scanproportion=.*/scanproportion=$scanproportion_postextend/" $WORKLOAD_FILE
        perl -i -p -e "s/^insertproportion=.*/insertproportion=$insertproportion_postextend/" $WORKLOAD_FILE
        perl -i -p -e "s/^readmodifywriteproportion=.*/readmodifywriteproportion=$readmodifywriteproportion_postextend/" $WORKLOAD_FILE
        perl -i -p -e "s/^requestdistribution=.*/requestdistribution=$requestdistribution_postextend/" $WORKLOAD_FILE
        perl -i -p -e "s/^operationcount=.*/operationcount=$opscount/" $WORKLOAD_FILE
        grep -q '^fieldlengthdistribution=' "$WORKLOAD_FILE" || echo -e "\nfieldlengthdistribution=histogram" >> "$WORKLOAD_FILE"
        source "$WORKLOAD_FILE"

        # Save the existing keys in the database
        mysql -u root --password= -e "
        USE $DB_NAME;
        SELECT YCSB_KEY FROM usertable;" | tail -n +2 > keys.txt

        # Execute the run phase
        log "=== Executing the run phase with extendproportion=0 and read/update proportions=0.5 ==="
        phase="run"
        $YCSB run jdbc -s -P $WORKLOAD_FILE -P $JDBC_PROPERTIES -p db.url="$DB_URL" -p db.user="$DB_USERNAME" -p db.passwd="$DB_PWD" -p fieldlengthhistogram="$HISTOGRAM_FILE" > $OUTPUT_CSV
        sstsize=$(sudo DB_PATH="$DB_PATH" bash -c 'du -sck "$DB_PATH"/*.sst | tail -n 1 | cut -f1')
        logsize=$(sudo DB_PATH="$DB_PATH" bash -c 'du -sck "$DB_PATH"/*.log | tail -n 1 | cut -f1') 
        cpu=$(ps -p $(pgrep -x mariadbd) -o %cpu | grep -o "[0-9.]*")
        memory=$(ps -p $(pgrep -x mariadbd) -o %mem | grep -o "[0-9.]*") 
        extract_myrocks_stats $DB_NAME
        write_result "FALSE"

        # Save the existing keys in the database to remove duplicates later
        mysql -u root --password= -e "
        USE $DB_NAME;
        SELECT YCSB_KEY FROM usertable;" | tail -n +2 > keys_after_run.txt

        # Sort both files
        sort keys.txt > keys_sorted.txt
        sort keys_after_run.txt > keys_after_sorted.txt

        # Get keys that are in keys_after_run.txt but NOT in keys.txt
        comm -13 keys_sorted.txt keys_after_sorted.txt > keys_to_delete.txt

        # Now delete those keys from MySQL
        while read key; do
          echo "DELETE FROM usertable WHERE YCSB_KEY='$key';"
        done < keys_to_delete.txt | mysql -u root --password= -D "$DB_NAME"

        rm -rf keys_after_run.txt keys.txt keys_after_sorted.txt keys_to_delete.txt

        mysql -u root --password= -e "
        USE $UNCHANGE_DB_NAME;
        SELECT YCSB_KEY FROM usertable;" | tail -n +2 > keys.txt

        # Close the RocksDB database
        #close_db "$DB_PATH"

        # Workload with unchanging value sizes
        phase="reference"
        $YCSB run jdbc -s -P $WORKLOAD_FILE -P $JDBC_PROPERTIES -p db.url="$UNCHANGE_DB_URL" -p db.user="$DB_USERNAME" -p db.passwd="$DB_PWD" -p fieldlengthhistogram="$HISTOGRAM_FILE" > $OUTPUT_CSV
        sstsize=$(sudo DB_PATH="$DB_PATH" bash -c 'du -sck "$DB_PATH"/*.sst | tail -n 1 | cut -f1')
        logsize=$(sudo DB_PATH="$DB_PATH" bash -c 'du -sck "$DB_PATH"/*.log | tail -n 1 | cut -f1') 
        cpu=$(ps -p $(pgrep -x mariadbd) -o %cpu | grep -o "[0-9.]*")
        memory=$(ps -p $(pgrep -x mariadbd) -o %mem | grep -o "[0-9.]*") 
        extract_myrocks_stats $UNCHANGE_DB_NAME
        write_result "FALSE"

        # Save the existing keys in the database to remove duplicates later
        mysql -u root --password= -e "
        USE $UNCHANGE_DB_NAME;
        SELECT YCSB_KEY FROM usertable;" | tail -n +2 > keys_after_run.txt

        # Sort both files
        sort keys.txt > keys_sorted.txt
        sort keys_after_run.txt > keys_after_sorted.txt

        # Get keys that are in keys_after_run.txt but NOT in keys.txt
        comm -13 keys_sorted.txt keys_after_sorted.txt > keys_to_delete.txt

        # Now delete those keys from MySQL
        while read key; do
          echo "DELETE FROM usertable WHERE YCSB_KEY='$key';"
        done < keys_to_delete.txt | mysql -u root --password= -D "$UNCHANGE_DB_NAME"

        rm -rf keys_after_run.txt keys.txt keys_after_sorted.txt keys_to_delete.txt
    
        if (( $((10*($epoch-1)+$run)) % 1 == 0 )); then
            phase="clean-run"
            
            echo "Backing up the database started"
            mysql -u root --password= -e "
            DROP DATABASE IF EXISTS $BACKUP_DB_NAME; 
            CREATE DATABASE $BACKUP_DB_NAME; 
            GRANT ALL PRIVILEGES ON $BACKUP_DB_NAME.* TO '$DB_USERNAME'@'localhost'; 
            FLUSH PRIVILEGES;"

            /usr/bin/mysqldump -u root --password= $DB_NAME > "$BACKUP_FILE"
            wait
            /usr/bin/mysql -u root --password= $BACKUP_DB_NAME < "$BACKUP_FILE"
            wait
            echo "Backing up the database finished"

            $YCSB run jdbc -s -P $WORKLOAD_FILE -P $JDBC_PROPERTIES -p db.url="$BACKUP_URL" -p db.user="$DB_USERNAME" -p db.passwd="$DB_PWD" -p fieldlengthhistogram="$HISTOGRAM_FILE" > $OUTPUT_CSV
            sstsize=$(sudo DB_PATH="$DB_PATH" bash -c 'du -sck "$DB_PATH"/*.sst | tail -n 1 | cut -f1')
            logsize=$(sudo DB_PATH="$DB_PATH" bash -c 'du -sck "$DB_PATH"/*.log | tail -n 1 | cut -f1') 
            cpu=$(ps -p $(pgrep -x mariadbd) -o %cpu | grep -o "[0-9.]*")
            memory=$(ps -p $(pgrep -x mariadbd) -o %mem | grep -o "[0-9.]*") 
            extract_myrocks_stats $BACKUP_DB_NAME
            rm -rf $BACKUP_FILE
            write_result "FALSE"

            # Revert and remove fieldlengthdistribution variable from workload file
            awk '!/^fieldlengthdistribution=/' "$WORKLOAD_FILE" | awk 'NF || NR == 1' > tmp && mv tmp "$WORKLOAD_FILE"

            # Key Sizes
            echo "Size computation started"
            mysql -u root --password= -e " 
            USE $BACKUP_DB_NAME; 
            SELECT YCSB_KEY, 
                    (LENGTHB(FIELD0) + LENGTHB(FIELD1) + LENGTHB(FIELD2) + LENGTHB(FIELD3) + 
                    LENGTHB(FIELD4) + LENGTHB(FIELD5) + LENGTHB(FIELD6) + LENGTHB(FIELD7) + 
                    LENGTHB(FIELD8) + LENGTHB(FIELD9)) AS Size FROM usertable;" | sed 's/\t/,/g' > $KEY_SIZE_LOG
            
            # Check if the output file exists, if not, create it with headers
            iteration=$((10*($epoch-1)+$run))
            if [[ ! -f "$KEY_SIZE_FILE_AFTER_RUN" ]]; then
                # Add header row (Key, Run1, Run2, ...)
                echo "Key,Run$iteration" > "$KEY_SIZE_FILE_AFTER_RUN"
            fi

            # If it's the first iteration, append keys and sizes for the first run
            if [[ "$iteration" -eq 1 ]]; then
                append_first_iteration $KEY_SIZE_LOG $KEY_SIZE_FILE_AFTER_RUN
            else
                append_subsequent_iterations $KEY_SIZE_LOG $KEY_SIZE_FILE_AFTER_RUN
            fi

            # Extract the recordcount from the workload file (assuming recordcount is in the form 'recordcount=1000')
            recordcount=$(grep -E '^recordcount=' "$WORKLOAD_FILE" | cut -d'=' -f2)

            # MySQL query to get the total size of all records
            total_size=$(mysql -u root --password= -e "
            USE $BACKUP_DB_NAME; 
            SELECT SUM(
                LENGTHB(FIELD0) + LENGTHB(FIELD1) + LENGTHB(FIELD2) + LENGTHB(FIELD3) + 
                LENGTHB(FIELD4) + LENGTHB(FIELD5) + LENGTHB(FIELD6) + LENGTHB(FIELD7) + 
                LENGTHB(FIELD8) + LENGTHB(FIELD9)
            ) FROM usertable;" -s -N)

            # Set average field length
            fieldlengthaverage=$(echo "$total_size / (10 * $recordcount)" | bc)

            # Chainging the value size for comparison
            perl -i -p -e "s/^fieldlength=.*/fieldlength=$fieldlengthaverage/" $WORKLOAD_FILE
            source "$WORKLOAD_FILE"

            mysql -u root --password= -e " 
            USE $BACKUP_DB_NAME; 
            DELETE FROM usertable;"

            # Resetting the database with new data load
            log "=== Executing the load phase for the comparison study ==="
            $YCSB load jdbc -s -P $WORKLOAD_FILE -P $JDBC_PROPERTIES -p db.url="$BACKUP_URL" -p db.user="$DB_USERNAME" -p db.passwd="$DB_PWD" > $OUTPUT_CSV
            
            # Chainging the value size for comparison
            perl -i -p -e "s/^fieldlength=.*/fieldlength=$fieldlengthoriginal/" $WORKLOAD_FILE
            source "$WORKLOAD_FILE"

            # Execute the run phase for average run
            log "=== Executing the run phase with extendproportion=0 and read/update proportions=0.5 ==="
            phase="avg-run"
            $YCSB run jdbc -s -P $WORKLOAD_FILE -P $JDBC_PROPERTIES -p db.url="$BACKUP_URL" -p db.user="$DB_USERNAME" -p db.passwd="$DB_PWD" > $OUTPUT_CSV
            sstsize=$(sudo DB_PATH="$DB_PATH" bash -c 'du -sck "$DB_PATH"/*.sst | tail -n 1 | cut -f1')
            logsize=$(sudo DB_PATH="$DB_PATH" bash -c 'du -sck "$DB_PATH"/*.log | tail -n 1 | cut -f1') 
            cpu=$(ps -p $(pgrep -x mariadbd) -o %cpu | grep -o "[0-9.]*")
            memory=$(ps -p $(pgrep -x mariadbd) -o %mem | grep -o "[0-9.]*") 
            extract_myrocks_stats $BACKUP_DB_NAME
            write_result "FALSE"
            fi
    done
done

# Delete intermediate temp files
rm -rf $LOG_FILE
rm -rf $OUTPUT_CSV
rm -rf $KEY_SIZE_LOG

log "=== All steps completed. Results are logged in $LOG_FILE ==="
