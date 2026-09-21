#!/bin/bash

#sudo mongod --config /etc/mongod.conf &         # Start first instance on 27017
#sudo mongod --config /etc/mongod_28018.conf &   # Start second instance on 28018

YCSB="bin/ycsb.sh"
MONGOSHELL="/usr/bin/mongosh"
MONGODUMP="mongodump"
MONGORESTORE="mongorestore"

# Change naming parameters here
TYPE="mongodb"
DIST="uniform" # "uniform" OR "zipfian"
SCALE="light" # "heavy" OR "light"
WORK="mixed" # e.g. "mixed", "pure", or "spreadrun"
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

# DB names
DB_NAME="ycsb"
BACKUP_DB_NAME="ycsb_backup"
UNCHANGE_DB_NAME="ycsb_unchange"

# Extend phase experiment parameters
extendproportion_extend="1"
readproportion_extend="0"
updateproportion_extend="0"
scanproportion_extend="0"
insertproportion_extend="0"
readmodifywriteproportion_extend="0"
requestdistribution_extend="uniform"

# After extend phase experiment parameters
extendproportion_postextend="0"
readproportion_postextend="0.5"
updateproportion_postextend="0.5"
scanproportion_postextend="0"
insertproportion_postextend="0"
extendvaluesize_postextend="0"
readmodifywriteproportion_postextend="0"
requestdistribution_postextend="uniform"

fieldlengthoriginal="100"
extendoperationcount="10000"

# Function to log and print messages
log() {
    echo "$1" | tee -a $LOG_FILE
}

# Clear the log file
> $LOG_FILE

# Function to write results as a csv 
write_result() {
    local first="$1"
    # Remove rows not starting with specific operations and filter specific operations
    filtered_output=$(awk '/^\[(INSERT|READ|UPDATE|SCAN|EXTEND)\]/' "$INPUT_FILE")
    overall_output=$(awk '/^\[(OVERALL)\]/' "$INPUT_FILE")

    if [ "$first" == "TRUE" ]; then   
        # Extract unique second values (except the first one) and create header
        header="Epoch,Phase,Recordcount,Readallfields,Requestdist,Operation,CPU,Memory,Readprop,Updateprop,Scanprop,Insertprop,Extendprop,Runtime(ms),Throughput(ops/sec),$(awk '{print $2}' <<< "$filtered_output" | sed 's/,$//' | uniq | awk '{ORS=","; print}')"
        echo "$header" > "$OUTPUT_FILE"
        return
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
        r=$((10 * (epoch - 1) + run))

        run_specific=()
        # Extract throughput
        while IFS= read -r inner_line; do
            # Extract third value
            tmp=$(echo "$inner_line" | awk '{print $3}' | sed 's/,$//')
            run_specific+=("$tmp")
        done <<< "$overall_output"

        # Append to the values variable
        if [ $k -eq 1 ]; then
            values_1="$r,$phase,$recordcount,$readallfields,$requestdistribution,$operation,$cpu,$memory,$readproportion,$updateproportion,$scanproportion,$insertproportion,$extendproportion,${run_specific[0]},${run_specific[1]},$third_value"            
            k=$((k + 1))
            prev_operation="$operation"
        elif [ $p -eq 1 ] && [ "$prev_operation" == "$operation" ]; then
            values_1="$values_1,$third_value"
        elif [ $p -eq 1 ] && [ "$prev_operation" != "$operation" ]; then
            values_2="$r,$phase,$recordcount,$readallfields,$requestdistribution,$operation,$cpu,$memory,$readproportion,$updateproportion,$scanproportion,$insertproportion,$extendproportion,${run_specific[0]},${run_specific[1]},$third_value"
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

delete_new_keys_mongo() {
  local db_name="$1"               # Required: name of the MongoDB database
  local collection="${2:-usertable}" # Optional: collection name (default: usertable)
  local key_field="${3:-_id}"      # Optional: key field (default: _id)

  local file_before="keys.txt"
  local file_after="keys_after_run.txt"
  local file_to_delete="keys_to_delete.txt"

  if [[ -z "$db_name" ]]; then
    echo "Usage: delete_new_keys_mongo <db_name> [collection] [key_field]"
    return 1
  fi

  # Sort the key files
  sort "$file_before" > keys_sorted.txt
  sort "$file_after" > keys_after_sorted.txt

  # Find keys that are only in keys_after_run.txt
  comm -13 keys_sorted.txt keys_after_sorted.txt > "$file_to_delete"

  echo "Deleting $(wc -l < "$file_to_delete") new keys from '$collection' in database '$db_name'..."

  # Create a JavaScript array of keys to delete
  local js_array="["$(awk '{printf "\"%s\",", $0}' "$file_to_delete" | sed 's/,$//')"]"

  # Execute MongoDB deleteMany command
  mongosh "mongodb://localhost:27017/$db_name?w=1" --quiet --eval \
    "db.getCollection('$collection').deleteMany({ \"$key_field\": { \$in: $js_array } })"

  echo "✅ Deletion complete."
}

# Delete the ycsb database on MongoDB if any
log "=== Deleting the ycsb database on MongoDB, if any ==="
$MONGOSHELL "mongodb://localhost:27017/$DB_NAME?w=1" --eval "db.dropDatabase()" | tee -a $LOG_FILE
$MONGOSHELL "mongodb://localhost:27017/$UNCHANGE_DB_NAME?w=1" --eval "db.dropDatabase()" | tee -a $LOG_FILE

# Execute the load phase
log "=== Executing the load phase ==="
phase="load"
$YCSB load mongodb -s -P $WORKLOAD_FILE -p "mongodb.url=mongodb://localhost:27017/$DB_NAME" > $OUTPUT_CSV
cpu=$(ps aux | grep '[m]ongod' | awk '{sum+=$3} END {print sum}')
memory=$(ps aux | grep '[m]ongod' | awk '{sum+=$6} END {print sum/1024}')
write_result "TRUE"

# Load unchange value size (reference) DB
$YCSB load mongodb -s -P $WORKLOAD_FILE -p "mongodb.url=mongodb://localhost:27017/$UNCHANGE_DB_NAME" > $OUTPUT_CSV

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
        $YCSB run mongodb -s -P $WORKLOAD_FILE -p "mongodb.url=mongodb://localhost:27017/$DB_NAME" > $OUTPUT_CSV
        cpu=$(ps aux | grep '[m]ongod' | awk '{sum+=$3} END {print sum}')
        memory=$(ps aux | grep '[m]ongod' | awk '{sum+=$6} END {print sum/1024}')
        write_result "FALSE"

        COLLECTION="usertable"     # Set your collection name

        # Key Sizes
        mongosh "mongodb://localhost:27017/$DB_NAME" --quiet --eval '
        const cursor = db.getCollection("'"$COLLECTION"'").find({}, { _id: 1, field0: 1, field1: 1, field2: 1, field3: 1, field4: 1, field5: 1, field6: 1, field7: 1, field8: 1, field9: 1 });
        while (cursor.hasNext()) {
          const doc = cursor.next();
          const key = doc._id;
          const valueOnly = {};
          for (let i = 0; i < 10; i++) {
            const fname = "field" + i;
            if (doc[fname] !== undefined) {
              valueOnly[fname] = doc[fname];
            }
          }
          const jsonStr = EJSON.stringify(valueOnly);
          const byteLength = new TextEncoder().encode(jsonStr).length;
          print(key + "," + byteLength);
        }
        ' > "$KEY_SIZE_LOG"

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

        # Execute the run phase
        log "=== Executing the run phase with extendproportion=0 and read/update proportions=0.5 ==="
        phase="run"
        $YCSB run mongodb -s -P $WORKLOAD_FILE -p "mongodb.url=mongodb://localhost:27017/$DB_NAME" -p fieldlengthhistogram="$HISTOGRAM_FILE" > $OUTPUT_CSV
        cpu=$(ps aux | grep '[m]ongod' | awk '{sum+=$3} END {print sum}')
        memory=$(ps aux | grep '[m]ongod' | awk '{sum+=$6} END {print sum/1024}')
        write_result "FALSE"

        # Workload with unchanging value sizes
        log "=== Executing the run phase with extendproportion=0 and read/update proportions=0.5 ==="
        phase="reference"
        $YCSB run mongodb -s -P $WORKLOAD_FILE -p "mongodb.url=mongodb://localhost:27017/$UNCHANGE_DB_NAME" -p fieldlengthhistogram="$HISTOGRAM_FILE" > $OUTPUT_CSV
        cpu=$(ps aux | grep '[m]ongod' | awk '{sum+=$3} END {print sum}')
        memory=$(ps aux | grep '[m]ongod' | awk '{sum+=$6} END {print sum/1024}')
        write_result "FALSE"

        if (( $((10*($epoch-1)+$run)) % 1 == 0 )); then
            phase="clean-run"

            echo "Backing up the database started"
            $MONGODUMP --uri="mongodb://localhost:27017/$DB_NAME" --archive | $MONGORESTORE --uri="mongodb://localhost:28018/$DB_NAME" --archive --drop
            echo "Backing up the database finished" 

            $YCSB run mongodb -s -P $WORKLOAD_FILE -p "mongodb.url=mongodb://localhost:28018/$DB_NAME" -p fieldlengthhistogram="$HISTOGRAM_FILE" > $OUTPUT_CSV
            cpu=$(ps aux | grep '[m]ongod' | awk '{sum+=$3} END {print sum}')
            memory=$(ps aux | grep '[m]ongod' | awk '{sum+=$6} END {print sum/1024}')
            write_result "FALSE"

            # Revert and remove fieldlengthdistribution variable from workload file
            awk '!/^fieldlengthdistribution=/' "$WORKLOAD_FILE" | awk 'NF || NR == 1' > tmp && mv tmp "$WORKLOAD_FILE"

            # Key Sizes
            mongosh "mongodb://localhost:27017/$DB_NAME" --quiet --eval '
            const cursor = db.getCollection("'"$COLLECTION"'").find({}, { _id: 1, field0: 1, field1: 1, field2: 1, field3: 1, field4: 1, field5: 1, field6: 1, field7: 1, field8: 1, field9: 1 });
            while (cursor.hasNext()) {
              const doc = cursor.next();
              const key = doc._id;
              const valueOnly = {};
              for (let i = 0; i < 10; i++) {
                const fname = "field" + i;
                if (doc[fname] !== undefined) {
                  valueOnly[fname] = doc[fname];
                }
              }
              const jsonStr = EJSON.stringify(valueOnly);
              const byteLength = new TextEncoder().encode(jsonStr).length;
              print(key + "," + byteLength);
            }
            ' > "$KEY_SIZE_LOG"

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

            # Extract the recordcount from the workload file
            recordcount=$(grep -E '^recordcount=' "$WORKLOAD_FILE" | cut -d'=' -f2)

            # Calculate total size of all records in MongoDB
            total_size=$(mongosh "mongodb://localhost:28018/$DB_NAME" --quiet --eval "
                JSON.stringify(db.getSiblingDB('$DB_NAME').usertable.aggregate([
                { \$project: { docSize: { \$bsonSize: '\$\$ROOT' } } },
                { \$group: { _id: null, totalSize: { \$sum: '\$docSize' } } }
                ]).toArray())
                " | jq -r '.[0].totalSize')

            # Calculate average field length
            fieldlengthaverage=$(echo "$total_size / (10 * $recordcount)" | bc)

            echo "$total_size" "$fieldlengthaverage"

            # Changing the value size for comparison
            perl -i -p -e "s/^fieldlength=.*/fieldlength=$fieldlengthaverage/" $WORKLOAD_FILE
            source "$WORKLOAD_FILE"

            $MONGOSHELL "mongodb://localhost:28018/$DB_NAME" --eval "db.dropDatabase()" | tee -a $LOG_FILE

            # Resetting the database with new data load
            log "=== Executing the load phase for the comparison study ==="
            $YCSB load mongodb -s -P $WORKLOAD_FILE -p "mongodb.url=mongodb://localhost:28018/$DB_NAME" > $OUTPUT_CSV

            # Changing the value size for comparison
            perl -i -p -e "s/^fieldlength=.*/fieldlength=$fieldlengthoriginal/" $WORKLOAD_FILE
            source "$WORKLOAD_FILE"

            # Execute the run phase
            phase="avg-run"
            $YCSB run mongodb -s -P $WORKLOAD_FILE -p "mongodb.url=mongodb://localhost:28018/$DB_NAME" > $OUTPUT_CSV
            cpu=$(ps aux | grep '[m]ongod' | awk '{sum+=$3} END {print sum}')
            memory=$(ps aux | grep '[m]ongod' | awk '{sum+=$6} END {print sum/1024}')
            write_result "FALSE"

            $MONGOSHELL "mongodb://localhost:28018/$DB_NAME" --eval "db.dropDatabase()" | tee -a $LOG_FILE

        fi
    done

done

# Delete intermediate temp files
rm -rf $LOG_FILE
rm -rf $OUTPUT_CSV

log "=== All steps completed. Results are logged in $LOG_FILE ==="
