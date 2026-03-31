#!/bin/bash
# ==============================================================================
# FFN 服务启动脚本 (YAML配置版本)
# 用法: ./ffn.sh [-d DEVICES] [-h]
# 示例: ./ffn.sh -d 12,13
# ==============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 加载YAML配置
source "${SCRIPT_DIR}/yaml_parser.sh" "${SCRIPT_DIR}/config.yaml"

# 加载Ascend环境
source "$ASCEND_TOOLKIT_PATH"

# 设置Profiler环境变量
export VLLM_ASCEND_MODEL_RUNNER_PROFILER_ENABLE=$VLLM_ASCEND_MODEL_RUNNER_PROFILER_ENABLE
export VLLM_ASCEND_MODEL_RUNNER_PROFILER_WAIT=$VLLM_ASCEND_MODEL_RUNNER_PROFILER_WAIT
export VLLM_ASCEND_MODEL_RUNNER_PROFILER_WARMUP=$VLLM_ASCEND_MODEL_RUNNER_PROFILER_WARMUP
export VLLM_ASCEND_MODEL_RUNNER_PROFILER_ACTIVE=$VLLM_ASCEND_MODEL_RUNNER_PROFILER_ACTIVE
export VLLM_ASCEND_MODEL_RUNNER_PROFILER_REPEAT=$VLLM_ASCEND_MODEL_RUNNER_PROFILER_REPEAT
export VLLM_ASCEND_MODEL_RUNNER_PROFILER_SKIP_FIRST=$VLLM_ASCEND_MODEL_RUNNER_PROFILER_SKIP_FIRST
export VLLM_ASCEND_MODEL_RUNNER_PROFILER_DIR="$VLLM_ASCEND_MODEL_RUNNER_PROFILER_DIR"
export VLLM_ASCEND_FFN_PROFILER_ENABLE=$VLLM_ASCEND_FFN_PROFILER_ENABLE
export VLLM_ASCEND_FFN_PROFILER_WAIT=$VLLM_ASCEND_FFN_PROFILER_WAIT
export VLLM_ASCEND_FFN_PROFILER_WARMUP=$VLLM_ASCEND_FFN_PROFILER_WARMUP
export VLLM_ASCEND_FFN_PROFILER_ACTIVE=$VLLM_ASCEND_FFN_PROFILER_ACTIVE
export VLLM_ASCEND_FFN_PROFILER_REPEAT=$VLLM_ASCEND_FFN_PROFILER_REPEAT
export VLLM_ASCEND_FFN_PROFILER_SKIP_FIRST=$VLLM_ASCEND_FFN_PROFILER_SKIP_FIRST
export VLLM_ASCEND_FFN_PROFILER_DIR="$VLLM_ASCEND_FFN_PROFILER_DIR"

# 默认值 (从YAML配置读取)
DEVICES=""
AFD_PORT="$AFD_PORT"
LOG_DIR="$LOG_DIR"
MODEL_PATH="$MODEL_PATH"
MASTER_ADDR="$MASTER_ADDR"
MASTER_PORT="$MASTER_PORT"
NETWORK_INTERFACE="$NETWORK_INTERFACE"
BSIZE=40
AFD_SIZE="8A8F"
NUM_DEVICES=8
UBATCH_SIZE=2
MAX_MODEL_LEN=8192
EXPERT_PER_RANK=8

# 解析命令行参数 (可覆盖YAML配置)
usage() {
    echo "用法: $0 [-d DEVICES] [-a AFD_PORT] [-l LOG_DIR] [-m MASTER_ADDR] [-t MASTER_PORT] [-i INTERFACE] [-M MAX_MODEL_LEN] [-e EXPERT_PER_RANK] [-h]"
    echo "  参数:"
    echo "    -d DEVICES         使用的卡号（必填）"
    echo "    -a AFD_PORT        AFD通信端口（默认: $AFD_PORT）"
    echo "    -l LOG_DIR         日志目录（默认: $LOG_DIR）"
    echo "    -m MASTER_ADDR     主节点IP地址（默认: $MASTER_ADDR）"
    echo "    -t MASTER_PORT     主节点端口（默认: $MASTER_PORT）"
    echo "    -i INTERFACE       网络接口名（默认: $NETWORK_INTERFACE）"
    echo "    -M MAX_MODEL_LEN   最大模型长度（默认: 8192）"
    echo "    -e EXPERT_PER_RANK 每rank专家数（默认: 8）"
    echo "    -h                 显示帮助信息"
    exit 1
}

while getopts "d:p:a:l:m:t:i:s:n:c:u:M:e:h" opt; do
    case $opt in
        d) DEVICES="$OPTARG" ;;
        p) PORT="$OPTARG" ;;
        a) AFD_PORT="$OPTARG" ;;
        l) LOG_DIR="$OPTARG" ;;
        m) MASTER_ADDR="$OPTARG" ;;
        t) MASTER_PORT="$OPTARG" ;;
        i) NETWORK_INTERFACE="$OPTARG" ;;
        s) BSIZE="$OPTARG" ;;
        n) NUM_DEVICES="$OPTARG" ;;
        c) AFD_SIZE="$OPTARG" ;;
        u) UBATCH_SIZE="$OPTARG" ;;
        M) MAX_MODEL_LEN="$OPTARG" ;;
        e) EXPERT_PER_RANK="$OPTARG" ;;
        h) usage ;;
        \?) echo "无效选项: -$OPTARG" >&2; usage ;;
        :) echo "选项 -$OPTARG 需要参数" >&2; usage ;;
    esac
done

# 设置环境变量
export HCCL_BUFFSIZE="$HCCL_BUFFSIZE"
export VLLM_LOGGING_LEVEL=DEBUG
export ASCEND_RT_VISIBLE_DEVICES="$DEVICES"

# 设置跨机通信环境变量
export MASTER_ADDR="$MASTER_ADDR"
export MASTER_PORT="$MASTER_PORT"
export GLOO_SOCKET_IFNAME="$NETWORK_INTERFACE"
export HCCL_SOCKET_IFNAME="$NETWORK_INTERFACE"

# 确保日志目录存在
mkdir -p "$LOG_DIR"

# 日志文件名
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
LOG_FILE="$LOG_DIR/ffn_${DEVICES//,/_}_${TIMESTAMP}.log"
echo "LOG_FILE: $LOG_FILE"

# 构建AFD配置JSON
# "multistream_info": {"enable": "True", "core_num": "8"}
AFD_CONFIG='{
  "afd_connector": "camp2pconnector",
  "num_afd_stages": "2",
  "afd_role": "ffn",
  "afd_extra_config": {
    "afd_size": "'$AFD_SIZE'"
  },
  "compute_gate_on_attention": "False",
  "multistream_info": {"enable": "True", "core_num": "8"},
  "afd_port": "'"$AFD_PORT"'"
}'
echo "AFD_CONFIG:$AFD_CONFIG"

COMPILATION_CONFIG='{"cudagraph_mode": "FULL_DECODE_ONLY", "cudagraph_capture_sizes": ['$BSIZE']}'
echo "BSIZE:$BSIZE"
echo "MAX_MODEL_LEN:$MAX_MODEL_LEN"
echo "EXPERT_PER_RANK:$EXPERT_PER_RANK"

# 启动ffn服务器
# --additional-config "{
#     "mix_placement": "True",
#     "expert_map_path": "/home/ttg/scripts/expert_map8_mix_dsv2_lite.json",
#     "enable_force_load_balance": "True",
#     "force_load_balance_topn_per_rank": '"$EXPERT_PER_RANK"'
#  }" \
vllm serve "$MODEL_PATH" \
    --data-parallel-size $NUM_DEVICES \
    --enable-expert-parallel \
    --max_num_batched_tokens $BSIZE \
    --compilation-config "$COMPILATION_CONFIG"  \
    --dbo-prefill-token-threshold 12 \
    --dbo-decode-token-threshold 2 \
    --no-enable-prefix-caching \
    --trust-remote-code \
    --gpu-memory-utilization 0.9 \
    --ubatch-size $UBATCH_SIZE \
    --max_num_seqs $BSIZE \
    --max-model-len $MAX_MODEL_LEN \
    --afd-config "$AFD_CONFIG" \
    --additional-config '{
        "enable_force_load_balance": "False"
    }' \
    --kv-transfer-config '{
        "kv_connector": "DecodeBenchConnector",
        "kv_role": "kv_both",
        "kv_connector_extra_config": {
            "fill_mean": 0.015,
            "fill_std": 0.0
        }
    }' \
   2>&1  > "$LOG_FILE"
