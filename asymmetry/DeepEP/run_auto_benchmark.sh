#!/bin/bash

# ==============================================================================
# 自动化性能基准测试脚本 (YAML配置版本 - String格式)
# 所有配置项在 config.yaml 中设置
# ==============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 加载YAML配置
source "${SCRIPT_DIR}/yaml_parser.sh" "${SCRIPT_DIR}/config.yaml"

# 从YAML配置读取参数
BSIZE_LIST="$BSIZE_LIST"
DATA_MULTIPLIER="$DATA_MULTIPLIER"
START_DEVICE="$START_DEVICE"

# 数组参数 (需要特殊处理)
read -ra EXPERT_PER_RANK_ARR <<< "$EXPERT_PER_RANK_LIST"
read -ra DP_ARR <<< "$DP_LIST"
read -ra INPUT_LEN_ARR <<< "$INPUT_LEN_LIST"

# ais_bench配置
CONFIG_PY="$CONFIG_PY"
MODEL_PY="$MODEL_PY"
WARMUP_REQUEST_COUNT="$WARMUP_REQUEST_COUNT"
WARMUP_MAX_OUT_LEN="$WARMUP_MAX_OUT_LEN"
FORMAL_MAX_OUT_LEN="$FORMAL_MAX_OUT_LEN"

# Profile配置
PROFILE_SRC_DIR="$PROFILE_SRC"

# 归档目录
ARCHIVE_ROOT="${SCRIPT_DIR}/benchmark_results"
GLOBAL_SUMMARY="${ARCHIVE_ROOT}/global_summary.csv"

# 日志打印
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

# 显示当前配置
show_config() {
    log "=========================================="
    log "当前配置 (来自 config.yaml):"
    log "  BSIZE_LIST: $BSIZE_LIST"
    log "  DP_ARR: ${DP_ARR[*]}"
    log "  INPUT_LEN_ARR: ${INPUT_LEN_ARR[*]}"
    log "  EXPERT_PER_RANK_ARR: ${EXPERT_PER_RANK_ARR[*]}"
    log "  START_DEVICE: $START_DEVICE"
    log "  DATA_MULTIPLIER: $DATA_MULTIPLIER"
    log "  CONFIG_PY: $CONFIG_PY"
    log "  MODEL_PY: $MODEL_PY"
    log "  WARMUP_REQUEST_COUNT: $WARMUP_REQUEST_COUNT"
    log "  WARMUP_MAX_OUT_LEN: $WARMUP_MAX_OUT_LEN"
    log "  FORMAL_MAX_OUT_LEN: $FORMAL_MAX_OUT_LEN"
    log "=========================================="
}

cleanup_vllm() {
    log "正在清理残留 VLLM 进程..."
    pkill -9 -f "vllm" 2>/dev/null || true
    pkill -9 -f "VLLM" 2>/dev/null || true
    pkill -9 python 2>/dev/null || true
    sleep 3
}

# String格式配置更新函数
update_configs() {
    local req_count=$1
    local batch_val=$2
    local input_len=$3
    local out_len=$4
    log "req_count:$1 batch_val:$2 input_len:$3 out_len:$4"

    sed -i "s/\"RequestCount\":[[:space:]]*[0-9]\+/\"RequestCount\": $req_count/" "$CONFIG_PY"
    sed -i "s/batch_size=[[:space:]]*[0-9]\+/batch_size=$batch_val/" "$MODEL_PY"
    sed -i "s/max_out_len=[[:space:]]*[0-9]\+/max_out_len=$out_len/" "$MODEL_PY"

    # StringConfig Input
    sed -i '/"Input"/,/\}/s/"MinValue":[[:space:]]*[0-9]\+/"MinValue": '"$input_len"'/g' "$CONFIG_PY"
    sed -i '/"Input"/,/\}/s/"MaxValue":[[:space:]]*[0-9]\+/"MaxValue": '"$input_len"'/g' "$CONFIG_PY"

    # StringConfig Output
    sed -i '/"Output"/,/\}/s/"Mean":[[:space:]]*[0-9]\+/"Mean": '"$out_len"'/g' "$CONFIG_PY"
    sed -i '/"Output"/,/\}/s/"MinValue":[[:space:]]*[0-9]\+/"MinValue": '"$out_len"'/g' "$CONFIG_PY"
    sed -i '/"Output"/,/\}/s/"MaxValue":[[:space:]]*[0-9]\+/"MaxValue": '"$out_len"'/g' "$CONFIG_PY"

    if ! grep -q "\"RequestCount\": $req_count" "$CONFIG_PY"; then
        log "错误：修改 RequestCount 失败"
        return 1
    fi
    return 0
}

archive_scenario() {
    local run_dir=$1
    local bsize=$2
    local dp=$3
    local total_batch=$4
    local req_count=$5
    local input_len=$6
    local out_len=$7
    local expert_per_rank=$8

    mkdir -p "${run_dir}/script" "${run_dir}/log" "${run_dir}/profile"
    cp "$CONFIG_PY" "${run_dir}/script/config_snapshot_synthetic.py"
    cp "$MODEL_PY" "${run_dir}/script/config_snapshot_model.py"

    cat > "${run_dir}/script/run_params.txt" << EOF
Run Timestamp: $(date)
Scenario: BSIZE=${bsize}, DP=${dp}, INPUT_LEN=${input_len}, OUTPUT_LEN=${out_len}, EXPERT_PER_RANK=${expert_per_rank}
  - Per Card Batch Size: $bsize
  - Data Parallel: $dp
  - Total Batch: $total_batch
  - Request Count: $req_count
EOF
    log "场景已归档至: $run_dir"
}

generate_report() {
    local log_file=$1
    local report_file=$2

    local tpot_avg="N/A" out_thr="N/A" total_thr="N/A"
    read -r tpot_avg tpot_min tpot_max tpot_med tpot_p75 tpot_p90 tpot_p99 <<< "$(grep "TPOT" "$log_file" | grep "total" | awk -F'│' '{for(i=4;i<=10;i++){gsub(/[[:space:]]+|ms/,"",$i);printf "%s ",$i}}')"

    out_raw=$(grep -i "Output Token Throughput" "$log_file" | grep "total" | head -1)
    [ -n "$out_raw" ] && out_thr=$(echo "$out_raw" | awk -F'│' '{gsub(/[[:space:]]+|token\/s/,"",$4);print $4}')

    total_raw=$(grep -i "Total Token Throughput" "$log_file" | grep "total" | head -1)
    [ -n "$total_raw" ] && total_thr=$(echo "$total_raw" | awk -F'│' '{gsub(/[[:space:]]+|token\/s/,"",$4);print $4}')

    [ "$tpot_avg" == "N/A" ] || [ "$out_thr" == "N/A" ] && log "警告：部分指标解析失败"

    cat > "$report_file" << EOF
================================================================
Benchmark Report - $(date)
TPOT (ms): Avg=$tpot_avg Min=$tpot_min Max=$tpot_max Med=$tpot_med P75=$tpot_p75 P90=$tpot_p90 P99=$tpot_p99
Output Throughput: $out_thr token/s
Total Throughput: $total_thr token/s
================================================================
EOF
    echo "$out_thr,$total_thr,$tpot_avg,$tpot_min,$tpot_max,$tpot_med,$tpot_p75,$tpot_p90,$tpot_p99"
}

# ================= 主执行流程 =================

log "=========================================="
log "启动自动化基准测试 (YAML配置版本 - String格式)"
log "=========================================="

show_config
mkdir -p "$ARCHIVE_ROOT"

[ ! -f "$GLOBAL_SUMMARY" ] && echo "Timestamp,Run_Dir,BSIZE,DP,Total_Batch,Request_Count,Status,OutTokenThru,INPUT_LEN,OUTPUT_LEN,EXPERT_PER_RANK,TPOT_AVG,TPOT_MIN,TPOT_MAX,TPOT_MED,TPOT_P75,TPOT_P90,TPOT_P99,Thru_Per_Die" > "$GLOBAL_SUMMARY"

for BSIZE in $BSIZE_LIST; do
    for DP in "${DP_ARR[@]}"; do
        for INPUT_LEN in "${INPUT_LEN_ARR[@]}"; do
            for EXPERT_PER_RANK in "${EXPERT_PER_RANK_ARR[@]}"; do
                log "------------------------------------------"
                log "测试: BSIZE=$BSIZE, DP=$DP, INPUT_LEN=$INPUT_LEN, EXPERT_PER_RANK=$EXPERT_PER_RANK"

                cleanup_vllm

                batch_size_value=$((DP * BSIZE))
                target_count=$((DATA_MULTIPLIER * batch_size_value))
                MAX_MODEL_LEN=$((INPUT_LEN + 3 * FORMAL_MAX_OUT_LEN))

                log "MAX_MODEL_LEN: $MAX_MODEL_LEN (input=$INPUT_LEN + 3*output=$FORMAL_MAX_OUT_LEN)"

                TIMESTAMP=$(date +%Y%m%d_%H%M%S)
                RUN_DIR="${ARCHIVE_ROOT}/BSIZE_${BSIZE}_DP${DP}_IN${INPUT_LEN}_OUT${FORMAL_MAX_OUT_LEN}_E${EXPERT_PER_RANK}_${TIMESTAMP}"

                DEVICE_START=$START_DEVICE
                DEVICE_END=$((START_DEVICE + DP - 1))
                DEVICES=$(seq -s, $DEVICE_START $DEVICE_END)

                log "启动服务 (DEVICES: $DEVICES)..."
                bash "${SCRIPT_DIR}/decode_only.sh" -d "$DEVICES" -s $BSIZE -l "${RUN_DIR}/log" -D $DP -e $EXPERT_PER_RANK -M $MAX_MODEL_LEN &
                PID_DECODE=$!
                sleep 90

                if ! kill -0 $PID_DECODE 2>/dev/null; then
                    log "错误：服务启动失败！"
                    mkdir -p "${RUN_DIR}/log"
                    echo "$(date),${RUN_DIR},$BSIZE,$DP,$batch_size_value,$target_count,START_FAILED,N/A,$INPUT_LEN,$FORMAL_MAX_OUT_LEN,$EXPERT_PER_RANK,N/A,N/A,N/A,N/A,N/A,N/A,N/A,N/A" >> "$GLOBAL_SUMMARY"
                    continue
                fi

                # 预热
                log "--- 预热 ---"
                if update_configs $WARMUP_REQUEST_COUNT $batch_size_value $INPUT_LEN $WARMUP_MAX_OUT_LEN; then
                    ais_bench --models vllm_api_stream_chat --datasets synthetic_gen_string --mode perf --debug > "${RUN_DIR}/log/warmup.log" 2>&1
                else
                    kill -9 $PID_DECODE 2>/dev/null
                    continue
                fi

                # 正式测试
                log "--- 正式测试 ---"
                if ! update_configs $target_count $batch_size_value $INPUT_LEN $FORMAL_MAX_OUT_LEN; then
                    kill -9 $PID_DECODE 2>/dev/null
                    continue
                fi

                archive_scenario "$RUN_DIR" "$BSIZE" "$DP" "$batch_size_value" "$target_count" "$INPUT_LEN" "$FORMAL_MAX_OUT_LEN" "$EXPERT_PER_RANK"

                START_TIME=$(date +%s)
                ais_bench --models vllm_api_stream_chat --datasets synthetic_gen_string --mode perf --debug > "${RUN_DIR}/log/benchmark.log" 2>&1
                DURATION=$(($(date +%s) - START_TIME))

                # 报告
                METRICS=$(generate_report "${RUN_DIR}/log/benchmark.log" "${RUN_DIR}/summary.txt")
                IFS=',' read -r OUT_THRU TOTAL_THRU TPOT_AVG TPOT_MIN TPOT_MAX TPOT_MED TPOT_P75 TPOT_P90 TPOT_P99 <<< "$METRICS"
                THROUGHPUT_PER_DIE=$(echo "scale=4; $OUT_THRU / $DP" | bc)

                echo "$(date +%Y-%m-%d_%H:%M:%S),${RUN_DIR},$BSIZE,$DP,$batch_size_value,$target_count,SUCCESS,$OUT_THRU,$INPUT_LEN,$FORMAL_MAX_OUT_LEN,$EXPERT_PER_RANK,$TPOT_AVG,$TPOT_MIN,$TPOT_MAX,$TPOT_MED,$TPOT_P75,$TPOT_P90,$TPOT_P99,$THROUGHPUT_PER_DIE" >> "$GLOBAL_SUMMARY"

                log "完成。耗时: ${DURATION}s"

                # Profile
                if [ -d "$PROFILE_SRC_DIR" ]; then
                    mv "$PROFILE_SRC_DIR"/* "${RUN_DIR}/profile/" 2>/dev/null
                fi

                kill -9 $PID_DECODE 2>/dev/null
                cleanup_vllm
                sleep 10
            done
        done
    done
done

log "=========================================="
log "所有测试完成！"
log "全局汇总: $GLOBAL_SUMMARY"
column -t -s, < "$GLOBAL_SUMMARY" 2>/dev/null && tail -n +2 "$GLOBAL_SUMMARY" | column -t -s,
