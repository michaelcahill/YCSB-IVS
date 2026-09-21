#!/bin/bash

YCSB="bin/ycsb.sh"

# DB names
DB_NAME="ycsb"
BACKUP_DB_NAME="ycsb_backup"
UNCHANGE_DB_NAME="ycsb_unchange"

# Path to the RocksDB data directory
DB_URL="jdbc:mysql://localhost:3306/$DB_NAME"
JDBC_PROPERTIES="jdbc-binding/conf/db.properties"
DB_USERNAME="ycsb_user"
DB_PWD="password"

# Change naming parameters here
TYPE="innodb"
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
#CREATE DATABASE ycsb; 
#GRANT ALL PRIVILEGES ON $DB_NAME.* TO '$DB_USERNAME'@'localhost'; 
#FLUSH PRIVILEGES;
#USE $DB_NAME;
#CREATE TABLE usertable ( YCSB_KEY VARCHAR(255) PRIMARY KEY NOT NULL,  
#FIELD0 VARCHAR(255), FIELD1 VARCHAR(255), FIELD2 VARCHAR(255), FIELD3 VARCHAR(255), FIELD4 VARCHAR(255), 
#FIELD5 VARCHAR(255), FIELD6 VARCHAR(255), FIELD7 VARCHAR(255),FIELD8 VARCHAR(255),  FIELD9 VARCHAR(255)) 
#ENGINE=RocksDB DEFAULT COLLATE=latin1_bin;"

# Flush database contents already existing
mysql -u root --password= -e " 
USE $DB_NAME; 
DELETE FROM usertable;"

# Function to log and print messages
log() {
    echo "$1" | tee -a $LOG_FILE
}

# Clear the log file and previous backups
> $LOG_FILE
rm -rf $BACKUP_DIR

# Function to write results as a csv 
write_result() {
    local first="$1"
    # Remove rows not starting with specific operations and filter specific operations
    filtered_output=$(awk '/^\[(INSERT|READ|UPDATE|SCAN|EXTEND)\]/' "$INPUT_FILE")
    overall_output=$(awk '/^\[(OVERALL)\]/' "$INPUT_FILE")

    if [ "$first" == "TRUE" ]; then   
        # Extract unique second values (except the first one) and create header
        header="Epoch,Phase,Recordcount,Readallfields,Requestdist,Operation,CPU,Memory,btree_height,adaptive_hash_hash_searches,adaptive_hash_non_hash_searches,background_log_sync,buffer_pool_dump_status,buffer_pool_load_status,buffer_pool_resize_status,buffer_pool_load_incomplete,buffer_pool_pages_data,buffer_pool_bytes_data,buffer_pool_pages_dirty,buffer_pool_bytes_dirty,buffer_pool_pages_flushed,buffer_pool_pages_free,buffer_pool_pages_made_not_young,buffer_pool_pages_made_young,buffer_pool_pages_misc,buffer_pool_pages_old,buffer_pool_pages_total,buffer_pool_pages_lru_flushed,buffer_pool_pages_lru_freed,buffer_pool_pages_split,buffer_pool_read_ahead_rnd,buffer_pool_read_ahead,buffer_pool_read_ahead_evicted,buffer_pool_read_requests,buffer_pool_reads,buffer_pool_wait_free,buffer_pool_write_requests,checkpoint_age,checkpoint_max_age,data_fsyncs,data_pending_fsyncs,data_pending_reads,data_pending_writes,data_read,data_reads,data_writes,data_written,dblwr_pages_written,dblwr_writes,deadlocks,history_list_length,ibuf_discarded_delete_marks,ibuf_discarded_deletes,ibuf_discarded_inserts,ibuf_free_list,ibuf_merged_delete_marks,ibuf_merged_deletes,ibuf_merged_inserts,ibuf_merges,ibuf_segment_size,ibuf_size,log_waits,log_write_requests,log_writes,lsn_current,lsn_flushed,lsn_last_checkpoint,master_thread_active_loops,master_thread_idle_loops,max_trx_id,mem_adaptive_hash,mem_dictionary,os_log_written,page_size,pages_created,pages_read,pages_written,row_lock_current_waits,row_lock_time,row_lock_time_avg,row_lock_time_max,row_lock_waits,num_open_files,truncated_status_writes,available_undo_logs,undo_truncations,page_compression_saved,num_pages_page_compressed,num_page_compressed_trim_op,num_pages_page_decompressed,num_pages_page_compression_error,num_pages_encrypted,num_pages_decrypted,have_lz4,have_lzo,have_lzma,have_bzip2,have_snappy,have_punch_hole,defragment_compression_failures,defragment_failures,defragment_count,instant_alter_column,onlineddl_rowlog_rows,onlineddl_rowlog_pct_used,onlineddl_pct_progress,encryption_rotation_pages_read_from_cache,encryption_rotation_pages_read_from_disk,encryption_rotation_pages_modified,encryption_rotation_pages_flushed,encryption_rotation_estimated_iops,encryption_n_merge_blocks_encrypted,encryption_n_merge_blocks_decrypted,encryption_n_rowlog_blocks_encrypted,encryption_n_rowlog_blocks_decrypted,encryption_n_temp_blocks_encrypted,encryption_n_temp_blocks_decrypted,encryption_num_key_requests,Readprop,Updateprop,Scanprop,Insertprop,Extendprop,Runtime(ms),Throughput(ops/sec),$(awk '{print $2}' <<< "$filtered_output" | sed 's/,$//' | uniq | awk '{ORS=","; print}')"
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
            values_1="$r,$phase,$recordcount,$readallfields,$requestdistribution,$operation,$cpu,$memory,$btree_height,$adaptive_hash_hash_searches,$adaptive_hash_non_hash_searches,$background_log_sync,$buffer_pool_dump_status,$buffer_pool_load_status,$buffer_pool_resize_status,$buffer_pool_load_incomplete,$buffer_pool_pages_data,$buffer_pool_bytes_data,$buffer_pool_pages_dirty,$buffer_pool_bytes_dirty,$buffer_pool_pages_flushed,$buffer_pool_pages_free,$buffer_pool_pages_made_not_young,$buffer_pool_pages_made_young,$buffer_pool_pages_misc,$buffer_pool_pages_old,$buffer_pool_pages_total,$buffer_pool_pages_lru_flushed,$buffer_pool_pages_lru_freed,$buffer_pool_pages_split,$buffer_pool_read_ahead_rnd,$buffer_pool_read_ahead,$buffer_pool_read_ahead_evicted,$buffer_pool_read_requests,$buffer_pool_reads,$buffer_pool_wait_free,$buffer_pool_write_requests,$checkpoint_age,$checkpoint_max_age,$data_fsyncs,$data_pending_fsyncs,$data_pending_reads,$data_pending_writes,$data_read,$data_reads,$data_writes,$data_written,$dblwr_pages_written,$dblwr_writes,$deadlocks,$history_list_length,$ibuf_discarded_delete_marks,$ibuf_discarded_deletes,$ibuf_discarded_inserts,$ibuf_free_list,$ibuf_merged_delete_marks,$ibuf_merged_deletes,$ibuf_merged_inserts,$ibuf_merges,$ibuf_segment_size,$ibuf_size,$log_waits,$log_write_requests,$log_writes,$lsn_current,$lsn_flushed,$lsn_last_checkpoint,$master_thread_active_loops,$master_thread_idle_loops,$max_trx_id,$mem_adaptive_hash,$mem_dictionary,$os_log_written,$page_size,$pages_created,$pages_read,$pages_written,$row_lock_current_waits,$row_lock_time,$row_lock_time_avg,$row_lock_time_max,$row_lock_waits,$num_open_files,$truncated_status_writes,$available_undo_logs,$undo_truncations,$page_compression_saved,$num_pages_page_compressed,$num_page_compressed_trim_op,$num_pages_page_decompressed,$num_pages_page_compression_error,$num_pages_encrypted,$num_pages_decrypted,$have_lz4,$have_lzo,$have_lzma,$have_bzip2,$have_snappy,$have_punch_hole,$defragment_compression_failures,$defragment_failures,$defragment_count,$instant_alter_column,$onlineddl_rowlog_rows,$onlineddl_rowlog_pct_used,$onlineddl_pct_progress,$encryption_rotation_pages_read_from_cache,$encryption_rotation_pages_read_from_disk,$encryption_rotation_pages_modified,$encryption_rotation_pages_flushed,$encryption_rotation_estimated_iops,$encryption_n_merge_blocks_encrypted,$encryption_n_merge_blocks_decrypted,$encryption_n_rowlog_blocks_encrypted,$encryption_n_rowlog_blocks_decrypted,$encryption_n_temp_blocks_encrypted,$encryption_n_temp_blocks_decrypted,$encryption_num_key_requests,$readproportion,$updateproportion,$scanproportion,$insertproportion,$extendproportion,${run_specific[0]},${run_specific[1]},$third_value"            
            k=$((k + 1))
            prev_operation="$operation"
        elif [ $p -eq 1 ] && [ "$prev_operation" == "$operation" ]; then
            values_1="$values_1,$third_value"
        elif [ $p -eq 1 ] && [ "$prev_operation" != "$operation" ]; then
            values_2="$r,$phase,$recordcount,$readallfields,$requestdistribution,$operation,$cpu,$memory,$btree_height,$adaptive_hash_hash_searches,$adaptive_hash_non_hash_searches,$background_log_sync,$buffer_pool_dump_status,$buffer_pool_load_status,$buffer_pool_resize_status,$buffer_pool_load_incomplete,$buffer_pool_pages_data,$buffer_pool_bytes_data,$buffer_pool_pages_dirty,$buffer_pool_bytes_dirty,$buffer_pool_pages_flushed,$buffer_pool_pages_free,$buffer_pool_pages_made_not_young,$buffer_pool_pages_made_young,$buffer_pool_pages_misc,$buffer_pool_pages_old,$buffer_pool_pages_total,$buffer_pool_pages_lru_flushed,$buffer_pool_pages_lru_freed,$buffer_pool_pages_split,$buffer_pool_read_ahead_rnd,$buffer_pool_read_ahead,$buffer_pool_read_ahead_evicted,$buffer_pool_read_requests,$buffer_pool_reads,$buffer_pool_wait_free,$buffer_pool_write_requests,$checkpoint_age,$checkpoint_max_age,$data_fsyncs,$data_pending_fsyncs,$data_pending_reads,$data_pending_writes,$data_read,$data_reads,$data_writes,$data_written,$dblwr_pages_written,$dblwr_writes,$deadlocks,$history_list_length,$ibuf_discarded_delete_marks,$ibuf_discarded_deletes,$ibuf_discarded_inserts,$ibuf_free_list,$ibuf_merged_delete_marks,$ibuf_merged_deletes,$ibuf_merged_inserts,$ibuf_merges,$ibuf_segment_size,$ibuf_size,$log_waits,$log_write_requests,$log_writes,$lsn_current,$lsn_flushed,$lsn_last_checkpoint,$master_thread_active_loops,$master_thread_idle_loops,$max_trx_id,$mem_adaptive_hash,$mem_dictionary,$os_log_written,$page_size,$pages_created,$pages_read,$pages_written,$row_lock_current_waits,$row_lock_time,$row_lock_time_avg,$row_lock_time_max,$row_lock_waits,$num_open_files,$truncated_status_writes,$available_undo_logs,$undo_truncations,$page_compression_saved,$num_pages_page_compressed,$num_page_compressed_trim_op,$num_pages_page_decompressed,$num_pages_page_compression_error,$num_pages_encrypted,$num_pages_decrypted,$have_lz4,$have_lzo,$have_lzma,$have_bzip2,$have_snappy,$have_punch_hole,$defragment_compression_failures,$defragment_failures,$defragment_count,$instant_alter_column,$onlineddl_rowlog_rows,$onlineddl_rowlog_pct_used,$onlineddl_pct_progress,$encryption_rotation_pages_read_from_cache,$encryption_rotation_pages_read_from_disk,$encryption_rotation_pages_modified,$encryption_rotation_pages_flushed,$encryption_rotation_estimated_iops,$encryption_n_merge_blocks_encrypted,$encryption_n_merge_blocks_decrypted,$encryption_n_rowlog_blocks_encrypted,$encryption_n_rowlog_blocks_decrypted,$encryption_n_temp_blocks_encrypted,$encryption_n_temp_blocks_decrypted,$encryption_num_key_requests,$readproportion,$updateproportion,$scanproportion,$insertproportion,$extendproportion,${run_specific[0]},${run_specific[1]},$third_value"
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


# Global variables for storing InnoDB buffer pool statistics
btree_height=""
adaptive_hash_hash_searches=""
adaptive_hash_non_hash_searches=""
background_log_sync=""
buffer_pool_dump_status=""
buffer_pool_load_status=""
buffer_pool_resize_status=""
buffer_pool_load_incomplete=""
buffer_pool_pages_data=""
buffer_pool_bytes_data=""
buffer_pool_pages_dirty=""
buffer_pool_bytes_dirty=""
buffer_pool_pages_flushed=""
buffer_pool_pages_free=""
buffer_pool_pages_made_not_young=""
buffer_pool_pages_made_young=""
buffer_pool_pages_misc=""
buffer_pool_pages_old=""
buffer_pool_pages_total=""
buffer_pool_pages_lru_flushed=""
buffer_pool_pages_lru_freed=""
buffer_pool_pages_split=""
buffer_pool_read_ahead_rnd=""
buffer_pool_read_ahead=""
buffer_pool_read_ahead_evicted=""
buffer_pool_read_requests=""
buffer_pool_reads=""
buffer_pool_wait_free=""
buffer_pool_write_requests=""
checkpoint_age=""
checkpoint_max_age=""
data_fsyncs=""
data_pending_fsyncs=""
data_pending_reads=""
data_pending_writes=""
data_read=""
data_reads=""
data_writes=""
data_written=""
dblwr_pages_written=""
dblwr_writes=""
deadlocks=""
history_list_length=""
ibuf_discarded_delete_marks=""
ibuf_discarded_deletes=""
ibuf_discarded_inserts=""
ibuf_free_list=""
ibuf_merged_delete_marks=""
ibuf_merged_deletes=""
ibuf_merged_inserts=""
ibuf_merges=""
ibuf_segment_size=""
ibuf_size=""
log_waits=""
log_write_requests=""
log_writes=""
lsn_current=""
lsn_flushed=""
lsn_last_checkpoint=""
master_thread_active_loops=""
master_thread_idle_loops=""
max_trx_id=""
mem_adaptive_hash=""
mem_dictionary=""
os_log_written=""
page_size=""
pages_created=""
pages_read=""
pages_written=""
row_lock_current_waits=""
row_lock_time=""
row_lock_time_avg=""
row_lock_time_max=""
row_lock_waits=""
num_open_files=""
truncated_status_writes=""
available_undo_logs=""
undo_truncations=""
page_compression_saved=""
num_pages_page_compressed=""
num_page_compressed_trim_op=""
num_pages_page_decompressed=""
num_pages_page_compression_error=""
num_pages_encrypted=""
num_pages_decrypted=""
have_lz4=""
have_lzo=""
have_lzma=""
have_bzip2=""
have_snappy=""
have_punch_hole=""
defragment_compression_failures=""
defragment_failures=""
defragment_count=""
instant_alter_column=""
onlineddl_rowlog_rows=""
onlineddl_rowlog_pct_used=""
onlineddl_pct_progress=""
encryption_rotation_pages_read_from_cache=""
encryption_rotation_pages_read_from_disk=""
encryption_rotation_pages_modified=""
encryption_rotation_pages_flushed=""
encryption_rotation_estimated_iops=""
encryption_n_merge_blocks_encrypted=""
encryption_n_merge_blocks_decrypted=""
encryption_n_rowlog_blocks_encrypted=""
encryption_n_rowlog_blocks_decrypted=""
encryption_n_temp_blocks_encrypted=""
encryption_n_temp_blocks_decrypted=""
encryption_num_key_requests=""

# Function to extract InnoDB buffer pool statistics
function extract_innodb_stats() {
    local db="$1"

    # Query to get buffer pool statistics from MariaDB
    buffer_pool_stats=$(mysql -u root --password= -e "USE $db; SHOW GLOBAL STATUS LIKE 'Innodb_%';")
    echo $buffer_pool_stats

    # Extract specific values using grep and awk
    btree_height=$(sudo bash -c '../inno_space/inno -f /var/lib/mysql/ycsb/usertable.ibd -c index-summary | grep "Btree hight" | awk -F: "{print \$2}" | tr -d " "')

    adaptive_hash_hash_searches=$(echo "$buffer_pool_stats" | grep "Innodb_adaptive_hash_hash_searches" | awk '{print $2}')
    adaptive_hash_non_hash_searches=$(echo "$buffer_pool_stats" | grep "Innodb_adaptive_hash_non_hash_searches" | awk '{print $2}')
    background_log_sync=$(echo "$buffer_pool_stats" | grep "Innodb_background_log_sync" | awk '{print $2}')
    buffer_pool_dump_status=$(echo "$buffer_pool_stats" | grep "Innodb_buffer_pool_dump_status" | awk '{print $2}')
    buffer_pool_load_status=$(echo "$buffer_pool_stats" | grep "Innodb_buffer_pool_load_status" | awk '{print $2}')
    buffer_pool_resize_status=$(echo "$buffer_pool_stats" | grep "Innodb_buffer_pool_resize_status" | awk '{print $2}')
    buffer_pool_load_incomplete=$(echo "$buffer_pool_stats" | grep "Innodb_buffer_pool_load_incomplete" | awk '{print $2}')
    buffer_pool_pages_data=$(echo "$buffer_pool_stats" | grep "Innodb_buffer_pool_pages_data" | awk '{print $2}')
    buffer_pool_bytes_data=$(echo "$buffer_pool_stats" | grep "Innodb_buffer_pool_bytes_data" | awk '{print $2}')
    buffer_pool_pages_dirty=$(echo "$buffer_pool_stats" | grep "Innodb_buffer_pool_pages_dirty" | awk '{print $2}')
    buffer_pool_bytes_dirty=$(echo "$buffer_pool_stats" | grep "Innodb_buffer_pool_bytes_dirty" | awk '{print $2}')
    buffer_pool_pages_flushed=$(echo "$buffer_pool_stats" | grep "Innodb_buffer_pool_pages_flushed" | awk '{print $2}')
    buffer_pool_pages_free=$(echo "$buffer_pool_stats" | grep "Innodb_buffer_pool_pages_free" | awk '{print $2}')
    buffer_pool_pages_made_not_young=$(echo "$buffer_pool_stats" | grep "Innodb_buffer_pool_pages_made_not_young" | awk '{print $2}')
    buffer_pool_pages_made_young=$(echo "$buffer_pool_stats" | grep "Innodb_buffer_pool_pages_made_young" | awk '{print $2}')
    buffer_pool_pages_misc=$(echo "$buffer_pool_stats" | grep "Innodb_buffer_pool_pages_misc" | awk '{print $2}')
    buffer_pool_pages_old=$(echo "$buffer_pool_stats" | grep "Innodb_buffer_pool_pages_old" | awk '{print $2}')
    buffer_pool_pages_total=$(echo "$buffer_pool_stats" | grep "Innodb_buffer_pool_pages_total" | awk '{print $2}')
    buffer_pool_pages_lru_flushed=$(echo "$buffer_pool_stats" | grep "Innodb_buffer_pool_pages_lru_flushed" | awk '{print $2}')
    buffer_pool_pages_lru_freed=$(echo "$buffer_pool_stats" | grep "Innodb_buffer_pool_pages_lru_freed" | awk '{print $2}')
    buffer_pool_pages_split=$(echo "$buffer_pool_stats" | grep "Innodb_buffer_pool_pages_split" | awk '{print $2}')
    buffer_pool_read_ahead_rnd=$(echo "$buffer_pool_stats" | grep "Innodb_buffer_pool_read_ahead_rnd" | awk '{print $2}')
    buffer_pool_read_ahead=$(echo $(echo "$buffer_pool_stats" | grep "Innodb_buffer_pool_read_ahead" | awk '{print $2}') | awk '{print $2}')
    buffer_pool_read_ahead_evicted=$(echo "$buffer_pool_stats" | grep "Innodb_buffer_pool_read_ahead_evicted" | awk '{print $2}')
    buffer_pool_read_requests=$(echo "$buffer_pool_stats" | grep "Innodb_buffer_pool_read_requests" | awk '{print $2}')
    buffer_pool_reads=$(echo "$buffer_pool_stats" | grep "Innodb_buffer_pool_reads" | awk '{print $2}')
    buffer_pool_wait_free=$(echo "$buffer_pool_stats" | grep "Innodb_buffer_pool_wait_free" | awk '{print $2}')
    buffer_pool_write_requests=$(echo "$buffer_pool_stats" | grep "Innodb_buffer_pool_write_requests" | awk '{print $2}')
    checkpoint_age=$(echo "$buffer_pool_stats" | grep "Innodb_checkpoint_age" | awk '{print $2}')
    checkpoint_max_age=$(echo "$buffer_pool_stats" | grep "Innodb_checkpoint_max_age" | awk '{print $2}')
    data_fsyncs=$(echo "$buffer_pool_stats" | grep "Innodb_data_fsyncs" | awk '{print $2}')
    data_pending_fsyncs=$(echo "$buffer_pool_stats" | grep "Innodb_data_pending_fsyncs" | awk '{print $2}')
    data_pending_reads=$(echo "$buffer_pool_stats" | grep "Innodb_data_pending_reads" | awk '{print $2}')
    data_pending_writes=$(echo "$buffer_pool_stats" | grep "Innodb_data_pending_writes" | awk '{print $2}')
    data_read=$(echo $(echo "$buffer_pool_stats" | grep "Innodb_data_read" | awk '{print $2}') | awk '{print $1}')
    data_reads=$(echo "$buffer_pool_stats" | grep "Innodb_data_reads" | awk '{print $2}')
    data_writes=$(echo "$buffer_pool_stats" | grep "Innodb_data_writes" | awk '{print $2}')
    data_written=$(echo "$buffer_pool_stats" | grep "Innodb_data_written" | awk '{print $2}')
    dblwr_pages_written=$(echo "$buffer_pool_stats" | grep "Innodb_dblwr_pages_written" | awk '{print $2}')
    dblwr_writes=$(echo "$buffer_pool_stats" | grep "Innodb_dblwr_writes" | awk '{print $2}')
    deadlocks=$(echo "$buffer_pool_stats" | grep "Innodb_deadlocks" | awk '{print $2}')
    history_list_length=$(echo "$buffer_pool_stats" | grep "Innodb_history_list_length" | awk '{print $2}')
    ibuf_discarded_delete_marks=$(echo "$buffer_pool_stats" | grep "Innodb_ibuf_discarded_delete_marks" | awk '{print $2}')
    ibuf_discarded_deletes=$(echo "$buffer_pool_stats" | grep "Innodb_ibuf_discarded_deletes" | awk '{print $2}')
    ibuf_discarded_inserts=$(echo "$buffer_pool_stats" | grep "Innodb_ibuf_discarded_inserts" | awk '{print $2}')
    ibuf_free_list=$(echo "$buffer_pool_stats" | grep "Innodb_ibuf_free_list" | awk '{print $2}')
    ibuf_merged_delete_marks=$(echo "$buffer_pool_stats" | grep "Innodb_ibuf_merged_delete_marks" | awk '{print $2}')
    ibuf_merged_deletes=$(echo "$buffer_pool_stats" | grep "Innodb_ibuf_merged_deletes" | awk '{print $2}')
    ibuf_merged_inserts=$(echo "$buffer_pool_stats" | grep "Innodb_ibuf_merged_inserts" | awk '{print $2}')
    ibuf_merges=$(echo "$buffer_pool_stats" | grep "Innodb_ibuf_merges" | awk '{print $2}')
    ibuf_segment_size=$(echo "$buffer_pool_stats" | grep "Innodb_ibuf_segment_size" | awk '{print $2}')
    ibuf_size=$(echo "$buffer_pool_stats" | grep "Innodb_ibuf_size" | awk '{print $2}')
    log_waits=$(echo "$buffer_pool_stats" | grep "Innodb_log_waits" | awk '{print $2}')
    log_write_requests=$(echo "$buffer_pool_stats" | grep "Innodb_log_write_requests" | awk '{print $2}')
    log_writes=$(echo "$buffer_pool_stats" | grep "Innodb_log_writes" | awk '{print $2}')
    lsn_current=$(echo "$buffer_pool_stats" | grep "Innodb_lsn_current" | awk '{print $2}')
    lsn_flushed=$(echo "$buffer_pool_stats" | grep "Innodb_lsn_flushed" | awk '{print $2}')
    lsn_last_checkpoint=$(echo "$buffer_pool_stats" | grep "Innodb_lsn_last_checkpoint" | awk '{print $2}')
    master_thread_active_loops=$(echo "$buffer_pool_stats" | grep "Innodb_master_thread_active_loops" | awk '{print $2}')
    master_thread_idle_loops=$(echo "$buffer_pool_stats" | grep "Innodb_master_thread_idle_loops" | awk '{print $2}')
    max_trx_id=$(echo "$buffer_pool_stats" | grep "Innodb_max_trx_id" | awk '{print $2}')
    mem_adaptive_hash=$(echo "$buffer_pool_stats" | grep "Innodb_mem_adaptive_hash" | awk '{print $2}')
    mem_dictionary=$(echo "$buffer_pool_stats" | grep "Innodb_mem_dictionary" | awk '{print $2}')
    os_log_written=$(echo "$buffer_pool_stats" | grep "Innodb_os_log_written" | awk '{print $2}')
    page_size=$(echo "$buffer_pool_stats" | grep "Innodb_page_size" | awk '{print $2}')
    pages_created=$(echo "$buffer_pool_stats" | grep "Innodb_pages_created" | awk '{print $2}')
    pages_read=$(echo "$buffer_pool_stats" | grep "Innodb_pages_read" | awk '{print $2}')
    pages_written=$(echo "$buffer_pool_stats" | grep "Innodb_pages_written" | awk '{print $2}')
    row_lock_current_waits=$(echo "$buffer_pool_stats" | grep "Innodb_row_lock_current_waits" | awk '{print $2}')
    row_lock_time=$(echo $(echo "$buffer_pool_stats" | grep "Innodb_row_lock_time" | awk '{print $2}') | awk '{print $1}')
    row_lock_time_avg=$(echo "$buffer_pool_stats" | grep "Innodb_row_lock_time_avg" | awk '{print $2}')
    row_lock_time_max=$(echo "$buffer_pool_stats" | grep "Innodb_row_lock_time_max" | awk '{print $2}')
    row_lock_waits=$(echo "$buffer_pool_stats" | grep "Innodb_row_lock_waits" | awk '{print $2}')
    num_open_files=$(echo "$buffer_pool_stats" | grep "Innodb_num_open_files" | awk '{print $2}')
    truncated_status_writes=$(echo "$buffer_pool_stats" | grep "Innodb_truncated_status_writes" | awk '{print $2}')
    available_undo_logs=$(echo "$buffer_pool_stats" | grep "Innodb_available_undo_logs" | awk '{print $2}')
    undo_truncations=$(echo "$buffer_pool_stats" | grep "Innodb_undo_truncations" | awk '{print $2}')
    page_compression_saved=$(echo "$buffer_pool_stats" | grep "Innodb_page_compression_saved" | awk '{print $2}')
    num_pages_page_compressed=$(echo "$buffer_pool_stats" | grep "Innodb_num_pages_page_compressed" | awk '{print $2}')
    num_page_compressed_trim_op=$(echo "$buffer_pool_stats" | grep "Innodb_num_page_compressed_trim_op" | awk '{print $2}')
    num_pages_page_decompressed=$(echo "$buffer_pool_stats" | grep "Innodb_num_pages_page_decompressed" | awk '{print $2}')
    num_pages_page_compression_error=$(echo "$buffer_pool_stats" | grep "Innodb_num_pages_page_compression_error" | awk '{print $2}')
    num_pages_encrypted=$(echo "$buffer_pool_stats" | grep "Innodb_num_pages_encrypted" | awk '{print $2}')
    num_pages_decrypted=$(echo "$buffer_pool_stats" | grep "Innodb_num_pages_decrypted" | awk '{print $2}')
    have_lz4=$(echo "$buffer_pool_stats" | grep "Innodb_have_lz4" | awk '{print $2}')
    have_lzo=$(echo "$buffer_pool_stats" | grep "Innodb_have_lzo" | awk '{print $2}')
    have_lzma=$(echo "$buffer_pool_stats" | grep "Innodb_have_lzma" | awk '{print $2}')
    have_bzip2=$(echo "$buffer_pool_stats" | grep "Innodb_have_bzip2" | awk '{print $2}')
    have_snappy=$(echo "$buffer_pool_stats" | grep "Innodb_have_snappy" | awk '{print $2}')
    have_punch_hole=$(echo "$buffer_pool_stats" | grep "Innodb_have_punch_hole" | awk '{print $2}')
    defragment_compression_failures=$(echo "$buffer_pool_stats" | grep "Innodb_defragment_compression_failures" | awk '{print $2}')
    defragment_failures=$(echo "$buffer_pool_stats" | grep "Innodb_defragment_failures" | awk '{print $2}')
    defragment_count=$(echo "$buffer_pool_stats" | grep "Innodb_defragment_count" | awk '{print $2}')
    instant_alter_column=$(echo "$buffer_pool_stats" | grep "Innodb_instant_alter_column" | awk '{print $2}')
    onlineddl_rowlog_rows=$(echo "$buffer_pool_stats" | grep "Innodb_onlineddl_rowlog_rows" | awk '{print $2}')
    onlineddl_rowlog_pct_used=$(echo "$buffer_pool_stats" | grep "Innodb_onlineddl_rowlog_pct_used" | awk '{print $2}')
    onlineddl_pct_progress=$(echo "$buffer_pool_stats" | grep "Innodb_onlineddl_pct_progress" | awk '{print $2}')
    encryption_rotation_pages_read_from_cache=$(echo "$buffer_pool_stats" | grep "Innodb_encryption_rotation_pages_read_from_cache" | awk '{print $2}')
    encryption_rotation_pages_read_from_disk=$(echo "$buffer_pool_stats" | grep "Innodb_encryption_rotation_pages_read_from_disk" | awk '{print $2}')
    encryption_rotation_pages_modified=$(echo "$buffer_pool_stats" | grep "Innodb_encryption_rotation_pages_modified" | awk '{print $2}')
    encryption_rotation_pages_flushed=$(echo "$buffer_pool_stats" | grep "Innodb_encryption_rotation_pages_flushed" | awk '{print $2}')
    encryption_rotation_estimated_iops=$(echo "$buffer_pool_stats" | grep "Innodb_encryption_rotation_estimated_iops" | awk '{print $2}')
    encryption_n_merge_blocks_encrypted=$(echo "$buffer_pool_stats" | grep "Innodb_encryption_n_merge_blocks_encrypted" | awk '{print $2}')
    encryption_n_merge_blocks_decrypted=$(echo "$buffer_pool_stats" | grep "Innodb_encryption_n_merge_blocks_decrypted" | awk '{print $2}')
    encryption_n_rowlog_blocks_encrypted=$(echo "$buffer_pool_stats" | grep "Innodb_encryption_n_rowlog_blocks_encrypted" | awk '{print $2}')
    encryption_n_rowlog_blocks_decrypted=$(echo "$buffer_pool_stats" | grep "Innodb_encryption_n_rowlog_blocks_decrypted" | awk '{print $2}')
    encryption_n_temp_blocks_encrypted=$(echo "$buffer_pool_stats" | grep "Innodb_encryption_n_temp_blocks_encrypted" | awk '{print $2}')
    encryption_n_temp_blocks_decrypted=$(echo "$buffer_pool_stats" | grep "Innodb_encryption_n_temp_blocks_decrypted" | awk '{print $2}')
    encryption_num_key_requests=$(echo "$buffer_pool_stats" | grep "Innodb_encryption_num_key_requests" | awk '{print $2}')

}

# Step 1: Delete the ycsb database on MongoDB if any
log "=== Deleting the ycsb database on MongoDB, if any ==="
#rm -rf "$DB_PATH"
#echo "RocksDB database at $DB_PATH has been deleted."

# Execute the load phase
log "=== Executing the load phase ==="
phase="load"
$YCSB load jdbc -s -P $WORKLOAD_FILE -P $JDBC_PROPERTIES -p db.url="$DB_URL" -p db.user="$DB_USERNAME" -p db.passwd="$DB_PWD" > $OUTPUT_CSV 
#sstsize=$(du -sck "$DB_PATH"/*.sst | tail -n 1| cut -f1)
#logsize=$(du -sck "$DB_PATH"/*.log | tail -n 1| cut -f1)
cpu=$(ps -p $(pgrep -x mariadbd) -o %cpu | grep -o "[0-9.]*")
memory=$(ps -p $(pgrep -x mariadbd) -o %mem | grep -o "[0-9.]*") 
extract_innodb_stats $DB_NAME
write_result "TRUE"

# Experiment parameters
for epoch in $(seq 1 10); do
    for run in $(seq 1 10); do

        # Set proportions for insert mode
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

        # Setting parameter values for read phase
        log "=== Setting parameter values for run phase ==="
        perl -i -p -e "s/^recordcount=.*/recordcount=$updatedrecordcount/" $WORKLOAD_FILE
        # Change operation count for read mode
        perl -i -p -e "s/^operationcount=.*/operationcount=$operationcount/" $WORKLOAD_FILE
        source "$WORKLOAD_FILE" 

        # Execute the run phase
        log "=== Executing the run phase with extendproportion=0 and read/update proportions=0.5 ==="
        phase="spread-run"
        $YCSB run jdbc -s -P $WORKLOAD_FILE -P $JDBC_PROPERTIES -p db.url="$DB_URL" -p db.user="$DB_USERNAME" -p db.passwd="$DB_PWD" > $OUTPUT_CSV
        cpu=$(ps -p $(pgrep -x mariadbd) -o %cpu | grep -o "[0-9.]*")
        memory=$(ps -p $(pgrep -x mariadbd) -o %mem | grep -o "[0-9.]*")
        extract_innodb_stats $DB_NAME
        write_result "FALSE"

    done
done

# Delete intermediate temp files
rm -rf $LOG_FILE
rm -rf $OUTPUT_CSV

log "=== All steps completed. Results are logged in $LOG_FILE ==="
