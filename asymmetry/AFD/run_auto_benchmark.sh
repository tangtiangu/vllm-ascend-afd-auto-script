#!/bin/bash

# ==============================================================================
# 自动化性能基准测试脚本 (YAML配置版本)
# 所有配置项在 config.yaml 中设置
# ==============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 加载YAML配置
source "${SCRIPT_DIR}/yaml_parser.sh" "${SCRIPT_DIR}/config.yaml"

# 从YAML配置读取参数
BSIZE_LIST="$BENCHMARK_BSIZE_LIST"
INPUT_LIST="$BENCHMARK_INPUT_LIST"
UBATCH_LIST="$BENCHMARK_UBATCH_LIST"
START_DEVICE="$BENCHMARK_START_DEVICE"
DATA_MULTIPLIER="$BENCHMARK_DATA_MULTIPLIER"

# 数组参数 (需要特殊处理)
read -ra ATTN_ARR <<< "$BENCHMARK_ATTN_ARR"
read -ra FFN_ARR <<< "$BENCHMARK_FFN_ARR"
read -ra EXPERT_PER_RANK_ARR <<< "$EXPERT_PER_RANK_LIST"

# ais_bench配置
CONFIG_PY="$AIS_BENCH_CONFIG_PY"
MODEL_PY="$AIS_BENCH_MODEL_PY"
WARMUP_REQUEST_COUNT="$AIS_BENCH_WARMUP_REQUEST_COUNT"
WARMUP_MAX_OUT_LEN="$AIS_BENCH_WARMUP_MAX_OUT_LEN"
FORMAL_MAX_OUT_LEN="$AIS_BENCH_FORMAL_MAX_OUT_LEN"

# Profile配置 (由 yaml_parser.sh 从 profiler.dir 映射)
# PROFILE_FFN_SRC, PROFILE_ATTN_SRC, PROFILE_PARSER_SCRIPT 已在 yaml_parser.sh 中设置

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
    log "  ATTN_ARR: ${ATTN_ARR[*]}"
    log "  FFN_ARR: ${FFN_ARR[*]}"
    log "  EXPERT_PER_RANK_ARR: ${EXPERT_PER_RANK_ARR[*]}"
    log "  INPUT_LIST: $INPUT_LIST"
    log "  UBATCH_LIST: $UBATCH_LIST"
    log "  START_DEVICE: $START_DEVICE"
    log "  DATA_MULTIPLIER: $DATA_MULTIPLIER"
    log "  CONFIG_PY: $CONFIG_PY"
    log "  MODEL_PY: $MODEL_PY"
    log "  WARMUP_REQUEST_COUNT: $WARMUP_REQUEST_COUNT"
    log "  FORMAL_MAX_OUT_LEN: $FORMAL_MAX_OUT_LEN"
    log "=========================================="
}

cleanup_vllm() {
    log "正在清理残留 VLLM 进程..."
    pkill -9 -f "vllm" 2>/dev/null || true
    pkill -9 -f "VLLM" 2>/dev/null || true
    sleep 3
}

update_configs() {
    local req_count=$1
    local batch_val=$2
    local out_len=$3
    local input_len=$4
    log "req_count:$1 batch_val:$2 out_len:$3 input_len:$4"
    sed -i "s/\"RequestCount\":[[:space:]]*[0-9]\+/\"RequestCount\": $req_count/" "$CONFIG_PY"
    sed -i "s/batch_size=[[:space:]]*[0-9]\+/batch_size=$batch_val/" "$MODEL_PY"
    sed -i "s/max_out_len=[[:space:]]*[0-9]\+/max_out_len=$out_len/" "$MODEL_PY"
    sed -i "s/\"RequestSize\":[[:space:]]*[0-9]\+/\"RequestSize\": $input_len/" "$CONFIG_PY"
    if ! grep -q "\"RequestCount\": $req_count" "$CONFIG_PY"; then
        log "错误：修改 RequestCount 失败"
        return 1
    fi
    return 0
}

archive_scenario() {
    local run_dir=$1
    local bsize=$2
    local total_batch=$3
    local req_count=$4
    local ubatch_size=$5
    local attn=$6
    local ffn=$7
    local max_model_len=$8
    local expert_per_rank=$9

    local script_dir="${run_dir}/script"
    local log_dir="${run_dir}/log"
    local profile_dir="${run_dir}/profile"

    mkdir -p "$script_dir" "$log_dir" "$profile_dir"

    cp "$CONFIG_PY" "${script_dir}/config_snapshot_synthetic.py"
    cp "$MODEL_PY" "${script_dir}/config_snapshot_model.py"

    cat > "${script_dir}/run_params.txt" << PARAMS_EOF
Run Timestamp: $(date)
Test Scenario: BSIZE=${bsize}, ubatch_size=${ubatch_size}, attn=${attn}, ffn=${ffn}, expert_per_rank=${expert_per_rank}
Calculated Parameters:
  - Per Card Batch Size (BSIZE): $bsize
  - Warmup Request Count: $WARMUP_REQUEST_COUNT
  - Formal Request Count: $req_count
  - Formal Max Out Len: $FORMAL_MAX_OUT_LEN
  - Max Model Len: $max_model_len (input_len + 3 * output_len)
  - Expert Per Rank: $expert_per_rank
  - Data Multiplier: $DATA_MULTIPLIER
Directory Structure:
  - script/: Configuration snapshots & params
  - log/: Execution logs
  - profile/: Performance profiling data (Moved after test)
PARAMS_EOF
    log "场景已归档至: $run_dir"
}

extract_all_stats() {
    local metric=$1
    local log_file=$2
    # ais_bench 使用 Unicode │ 作为分隔符，行首有 │ 导致 $1 为空
    # 字段: $2=metric, $3=stage, $4=Avg, $5=Min, $6=Max, $7=Med, $8=P75, $9=P90, $10=P99
    grep "$metric" "$log_file" | grep "total" | awk -F'│' '{
        for(i=4; i<=10; i++) {
            gsub(/[[:space:]]+|(ms|token\/s)/, "", $i);
            printf "%s ", $i
        }
    }'
}

generate_report() {
    local log_file=$1
    local report_file=$2
    local status="SUCCESS"
    local tpot_avg="N/A"
    local out_tok_thru_avg="N/A"
    local total_tok_thru_avg="N/A"

    read -r tpot_avg tpot_min tpot_max tpot_med tpot_p75 tpot_p90 tpot_p99 <<< "$(extract_all_stats "TPOT" "$log_file")"

    # 提取 Output Token Throughput (使用 Unicode │ 分隔符，$4 是值)
    out_tok_raw=$(grep -i "Output Token Throughput" "$log_file" | grep "total" | head -1)
    if [ -n "$out_tok_raw" ]; then
        out_tok_thru_avg=$(echo "$out_tok_raw" | awk -F'│' '{gsub(/[[:space:]]+|token\/s/, "", $4); print $4}')
        [ -z "$out_tok_thru_avg" ] && out_tok_thru_avg="N/A"
    fi

    # 提取 Total Token Throughput (使用 Unicode │ 分隔符，$4 是值)
    total_tok_raw=$(grep -i "Total Token Throughput" "$log_file" | grep "total" | head -1)
    if [ -n "$total_tok_raw" ]; then
        total_tok_thru_avg=$(echo "$total_tok_raw" | awk -F'│' '{gsub(/[[:space:]]+|token\/s/, "", $4); print $4}')
        [ -z "$total_tok_thru_avg" ] && total_tok_thru_avg="N/A"
    fi

    if [ "$tpot_avg" == "N/A" ] || [ "$out_tok_thru_avg" == "N/A" ] || [ "$total_tok_thru_avg" == "N/A" ]; then
        status="PARTIAL_PARSE"
        log "警告：指标解析失败！TPOT:$tpot_avg, OutThru:$out_tok_thru_avg, TotalThru:$total_tok_thru_avg"
    fi

    cat > "$report_file" << REPORT_EOF
================================================================
Benchmark Summary Report
Generated: $(date)
Status: $status
================================================================

Key Metrics (Average Values):
  1. TPOT (Time Per Output Token):       $tpot_avg ms
  2. Output Token Throughput:            $out_tok_thru_avg token/s
  3. Total Token Throughput:             $total_tok_thru_avg token/s

File Locations:
  - Full Log: log/benchmark.log
  - Configs:  script/config_snapshot_*.py
  - Params:   script/run_params.txt
  - Profile:  profile/ (Check for profiling data)
================================================================
REPORT_EOF
    echo "$status,$out_tok_thru_avg,$total_tok_thru_avg,$tpot_avg,$tpot_min,$tpot_max,$tpot_med,$tpot_p75,$tpot_p90,$tpot_p99"
}

# 生成单次测试结果YAML文件
generate_result_yaml() {
    local yaml_file=$1
    local bsize=$2
    local dp=$3
    local ubatch_size=$4
    local attn_cnt=$5
    local ffn_cnt=$6
    local global_batch=$7
    local data_mult=$8
    local input_len=$9
    local output_len=${10}
    local warmup_req=${11}
    local formal_req=${12}
    local tpot_avg=${13}
    local tpot_min=${14}
    local tpot_max=${15}
    local tpot_med=${16}
    local tpot_p75=${17}
    local tpot_p90=${18}
    local tpot_p99=${19}
    local out_token_thr=${20}
    local thr_per_die=${21}
    local max_model_len=${22}
    local expert_per_rank=${23}

    cat > "$yaml_file" << YAML_EOF
# ==============================================================================
# 单次基准测试结果
# 生成时间: $(date)
# ==============================================================================

test_config:
  batch_size: $bsize
  dp: $dp
  ubatch_size: $ubatch_size
  attn_cnt: $attn_cnt
  ffn_cnt: $ffn_cnt
  expert_per_rank: $expert_per_rank
  global_batch_size: $global_batch
  data_multiplier: $data_mult

request_config:
  input_len: $input_len
  output_len: $output_len
  warmup_request_count: $warmup_req
  formal_request_count: $formal_req
  max_model_len: $max_model_len

metrics:
  tpot_avg: $tpot_avg
  tpot_min: $tpot_min
  tpot_max: $tpot_max
  tpot_med: $tpot_med
  tpot_p75: $tpot_p75
  tpot_p90: $tpot_p90
  tpot_p99: $tpot_p99
  out_token_throughput: $out_token_thr
  throughput_per_die: $thr_per_die
YAML_EOF
    log "结果YAML已生成: $yaml_file"
}

# ================= 主执行流程 =================

log "=========================================="
log "启动自动化基准测试 (YAML配置版本)"
log "=========================================="

show_config

mkdir -p "$ARCHIVE_ROOT"

if [ ! -f "$GLOBAL_SUMMARY" ]; then
    echo "Timestamp,Run_Dir,BSIZE,DP,Total_Batch_Size,Request_Count,Status,OutTokenThru(token/s),ATTN_CNT,FFN_CNT,EXPERT_PER_RANK,TPOT_AVG,TPOT_MIN,TPOT_MAX,TPOT_MED,TPOT_P75,TPOT_P90,TPOT_P99,THROUGHPUT_PER_DIE" > "$GLOBAL_SUMMARY"
fi

NUM_PAIRS=${#ATTN_ARR[@]}
for BSIZE in $BSIZE_LIST; do
    for (( i=0; i<$NUM_PAIRS; i++ )); do
        for INPUT_LEN in $INPUT_LIST; do
            for UBATCH_SIZE in $UBATCH_LIST; do
                for EXPERT_PER_RANK in "${EXPERT_PER_RANK_ARR[@]}"; do
                ATTN=${ATTN_ARR[$i]}
                FFN=${FFN_ARR[$i]}
                log "配置中: B=$BSIZE, A=$ATTN, F=$FFN, E=$EXPERT_PER_RANK"

                cleanup_vllm

                DP=${ATTN_ARR[$i]}
                batch_size_value=$((DP * BSIZE))
                target_count=$((DATA_MULTIPLIER * batch_size_value))

                # 计算 max_model_len = input_len + 3 * output_len
                MAX_MODEL_LEN=$((INPUT_LEN + 3 * FORMAL_MAX_OUT_LEN))
                log "MAX_MODEL_LEN: $MAX_MODEL_LEN (input=$INPUT_LEN + 3*output=$FORMAL_MAX_OUT_LEN)"

                TIMESTAMP=$(date +%Y%m%d_%H%M%S)
                RUN_DIR="${ARCHIVE_ROOT}/BSIZE_${BSIZE}_${ATTN}A${FFN}F_UB${UBATCH_SIZE}_IN${INPUT_LEN}_E${EXPERT_PER_RANK}_${TIMESTAMP}"

                # 计算 FFN 的设备字符串
                FFN_START=$((START_DEVICE))
                FFN_END=$((START_DEVICE + FFN - 1))
                FFN_DEVICES=$(seq -s, $FFN_START $FFN_END)

                # 计算 ATTN 的设备字符串
                ATTN_START=$((START_DEVICE + FFN))
                ATTN_END=$((START_DEVICE + FFN + ATTN - 1))
                ATTN_DEVICES=$(seq -s, $ATTN_START $ATTN_END)

                AFD_SIZE="${ATTN}A${FFN}F"

                log "启动后端服务..."
                bash "${SCRIPT_DIR}/attn.sh" -d "$ATTN_DEVICES" -s $BSIZE -l "${RUN_DIR}/log" -n $ATTN -c $AFD_SIZE -u $UBATCH_SIZE -M $MAX_MODEL_LEN -e $EXPERT_PER_RANK &
                PID_ATT=$!

                bash "${SCRIPT_DIR}/ffn.sh" -d "$FFN_DEVICES" -s $BSIZE -l "${RUN_DIR}/log" -n $FFN -c $AFD_SIZE -u $UBATCH_SIZE -M $MAX_MODEL_LEN -e $EXPERT_PER_RANK &
                PID_FFN=$!

                log "等待服务启动 (90秒)..."
                sleep 90

                if ! kill -0 $PID_ATT 2>/dev/null || ! kill -0 $PID_FFN 2>/dev/null; then
                    log "错误：后端服务启动失败！"
                    echo "Service Start Failed" > "${RUN_DIR}/log/error.log"
                    echo "$(date),${RUN_DIR},$BSIZE,$DP,$batch_size_value,$target_count,START_FAILED,N/A,N/A,N/A" >> "$GLOBAL_SUMMARY"
                    continue
                fi
                log "后端服务启动成功"

                # === 预热 ===
                log "--- 阶段 1: 预热 ---"
                WARMUP_LOG="${RUN_DIR}/log/warmup.log"
                log "WARMUP_REQUEST_COUNT:$WARMUP_REQUEST_COUNT batch_size_value:$batch_size_value WARMUP_MAX_OUT_LEN:$WARMUP_MAX_OUT_LEN"
                if update_configs $WARMUP_REQUEST_COUNT $batch_size_value $WARMUP_MAX_OUT_LEN $INPUT_LEN; then
                    ais_bench --models vllm_api_stream_chat --datasets synthetic_gen_string --mode perf --debug > "$WARMUP_LOG" 2>&1
                    log "预热完成。"
                else
                    log "预热配置失败，跳过。"
                    kill -9 $PID_ATT $PID_FFN 2>/dev/null
                    continue
                fi

                # === 正式测试 ===
                log "--- 阶段 2: 正式测试 ---"
                log "target_count:$target_count batch_size_value:$batch_size_value FORMAL_MAX_OUT_LEN:$FORMAL_MAX_OUT_LEN"
                if ! update_configs $target_count $batch_size_value $FORMAL_MAX_OUT_LEN $INPUT_LEN; then
                    log "正式配置失败，跳过。"
                    kill -9 $PID_ATT $PID_FFN 2>/dev/null
                    continue
                fi

                archive_scenario "$RUN_DIR" "$BSIZE" "$batch_size_value" "$target_count" "$UBATCH_SIZE" "$ATTN" "$FFN" "$MAX_MODEL_LEN" "$EXPERT_PER_RANK"

                FORMAL_LOG="${RUN_DIR}/log/benchmark.log"
                log "运行 ais_bench..."

                START_TIME=$(date +%s)
                ais_bench --models vllm_api_stream_chat --datasets synthetic_gen_string --mode perf --debug > "$FORMAL_LOG" 2>&1
                EXIT_CODE=$?
                END_TIME=$(date +%s)
                DURATION=$((END_TIME - START_TIME))

                if [ $EXIT_CODE -ne 0 ]; then
                    log "警告：ais_bench 返回非零代码 ($EXIT_CODE)，继续尝试提取数据。"
                fi

                # === 生成报告 ===
                REPORT_FILE="${RUN_DIR}/summary.txt"
                METRICS=$(generate_report "$FORMAL_LOG" "$REPORT_FILE")
                IFS=',' read -r STATUS OUT_THRU_VAL TOTAL_THRU_VAL TPOT_AVG TPOT_MIN TPOT_MAX TPOT_MED TPOT_P75 TPOT_P90 TPOT_P99 <<< "$METRICS"
                THROUGHPUT_PER_DIE=$(echo "scale=4; $OUT_THRU_VAL / ($ATTN + $FFN)" | bc)

                # === 生成单次测试结果YAML ===
                RESULT_YAML="${RUN_DIR}/result.yaml"
                generate_result_yaml "$RESULT_YAML" \
                    "$BSIZE" "$DP" "$UBATCH_SIZE" "$ATTN" "$FFN" \
                    "$batch_size_value" "$DATA_MULTIPLIER" \
                    "$INPUT_LEN" "$FORMAL_MAX_OUT_LEN" \
                    "$WARMUP_REQUEST_COUNT" "$target_count" \
                    "$TPOT_AVG" "$TPOT_MIN" "$TPOT_MAX" "$TPOT_MED" \
                    "$TPOT_P75" "$TPOT_P90" "$TPOT_P99" \
                    "$OUT_THRU_VAL" "$THROUGHPUT_PER_DIE" "$MAX_MODEL_LEN" "$EXPERT_PER_RANK"

                echo "$(date +%Y-%m-%d_%H:%M:%S),${RUN_DIR},$BSIZE,$DP,$batch_size_value,$target_count,$STATUS,$OUT_THRU_VAL,$ATTN,$FFN,$EXPERT_PER_RANK,$TPOT_AVG,$TPOT_MIN,$TPOT_MAX,$TPOT_MED,$TPOT_P75,$TPOT_P90,$TPOT_P99,$THROUGHPUT_PER_DIE" >> "$GLOBAL_SUMMARY"

                log "测试完成。耗时: ${DURATION}s"
                log "结果摘要:"
                cat "$REPORT_FILE"

                # ==========================================================
                # Profile 移动与解析
                # ==========================================================
                log ">>> 开始处理 Profile 数据..."

                PROFILE_FFN_DIR="${RUN_DIR}/profile/ffn"
                PROFILE_ATTENTION_DIR="${RUN_DIR}/profile/attention"
                mkdir -p "$PROFILE_FFN_DIR"
                mkdir -p "$PROFILE_ATTENTION_DIR"

                # 处理 FFN Profile
                log "  [FFN] 查找并处理 Profile 数据..."
                if [ -d "$PROFILE_FFN_SRC" ]; then
                    FFN_PATTERN=$(ls -d "$PROFILE_FFN_SRC"/*/ 2>/dev/null | xargs -I {} basename {} | grep -oE '[0-9]{10,}' | head -n 1 | cut -c1-11)

                    if [ -n "$FFN_PATTERN" ]; then
                        log "  [FFN] 找到 Pattern: $FFN_PATTERN"
                        log "  [FFN] 执行 Python 解析..."
                        python "$PROFILE_PARSER_SCRIPT" "$PROFILE_FFN_SRC" "$FFN_PATTERN" || log "  [FFN] Python 脚本执行完成 (可能有警告)"

                        log "  [FFN] 开始移动文件到 $PROFILE_FFN_DIR..."
                        shopt -s dotglob nullglob
                        count=0
                        for item in "$PROFILE_FFN_SRC"/*; do
                            if [ -e "$item" ]; then
                                mv "$item" "$PROFILE_FFN_DIR"/ && ((count++))
                            fi
                        done
                        shopt -u dotglob nullglob
                        log "  [FFN] 成功移动 $count 个项目"
                    else
                        log "  [FFN] 未找到有效的 Pattern，跳过解析。"
                    fi
                else
                    log "  [FFN] 源目录 $PROFILE_FFN_SRC 不存在，跳过。"
                fi

                # 处理 Attention Profile
                log "  [ATTN] 查找并处理 Profile 数据..."
                if [ -d "$PROFILE_ATTN_SRC" ]; then
                    ATTN_PATTERN=$(ls -d "$PROFILE_ATTN_SRC"/*/ 2>/dev/null | xargs -I {} basename {} | grep -oE '[0-9]{10,}' | head -n 1 | cut -c1-11)

                    if [ -n "$ATTN_PATTERN" ]; then
                        log "  [ATTN] 找到 Pattern: $ATTN_PATTERN"
                        log "  [ATTN] 开始移动文件到 $PROFILE_ATTENTION_DIR..."
                        shopt -s dotglob nullglob
                        count=0
                        for item in "$PROFILE_ATTN_SRC"/*; do
                            if [ -e "$item" ]; then
                                mv "$item" "$PROFILE_ATTENTION_DIR"/ && ((count++))
                            fi
                        done
                        shopt -u dotglob nullglob
                        log "  [ATTN] 成功移动 $count 个项目"
                    else
                        log "  [ATTN] 未找到有效的 Pattern，跳过解析。"
                    fi
                else
                    log "  [ATTN] 源目录 $PROFILE_ATTN_SRC 不存在，跳过。"
                fi

                log ">>> Profile 处理全部结束！"

                # === 清理 ===
                log "清理进程..."
                kill -9 $PID_ATT $PID_FFN 2>/dev/null
                cleanup_vllm

                log "冷却 10 秒..."
                sleep 10
                done
            done
        done
    done
done

log "=========================================="
log "所有测试完成！"
log "全局汇总文件: $GLOBAL_SUMMARY"

if command -v column &> /dev/null; then
    echo "=== 全局测试结果预览 ==="
    tail -n +2 "$GLOBAL_SUMMARY" | column -t -s,
fi
