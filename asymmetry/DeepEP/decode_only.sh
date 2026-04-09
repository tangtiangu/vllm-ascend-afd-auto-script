#!/bin/bash
# ==============================================================================
# Decode Only 服务启动脚本 (YAML配置版本)
# 用法: ./decode_only.sh [-d DEVICES] [-s BSIZE] [-l LOG_DIR] [-e EXPERT_PER_RANK] [-h]
# ==============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 加载YAML配置
source "${SCRIPT_DIR}/yaml_parser.sh" "${SCRIPT_DIR}/config.yaml"

# 加载Ascend环境
source "$ASCEND_TOOLKIT_PATH"

# 默认值 (从YAML配置读取)
DEVICES=""
BSIZE=40
LOG_DIR="$LOG_DIR"
MODEL_PATH="$MODEL_PATH"
LOCAL_IP="$LOCAL_IP"
NETWORK_INTERFACE="$NETWORK_INTERFACE"
PORT="$PORT"
DP=1
TP="$TP"
EXPERT_PER_RANK=8
MAX_MODEL_LEN=16384

# 解析命令行参数 (可覆盖YAML配置)
usage() {
    echo "用法: $0 [-d DEVICES] [-s BSIZE] [-l LOG_DIR] [-p PORT] [-D DP] [-e EXPERT_PER_RANK] [-M MAX_MODEL_LEN] [-h]"
    echo "  参数:"
    echo "    -d DEVICES         使用的卡号（默认: 从配置读取）"
    echo "    -s BSIZE           批次大小（默认: 40）"
    echo "    -l LOG_DIR         日志目录（默认: $LOG_DIR）"
    echo "    -p PORT            HTTP服务端口（默认: $PORT）"
    echo "    -D DP              数据并行大小（默认: 1）"
    echo "    -e EXPERT_PER_RANK 每rank专家数（默认: 8）"
    echo "    -M MAX_MODEL_LEN   最大模型长度（默认: 16384）"
    echo "    -h                 显示帮助信息"
    exit 0
}

while getopts "d:s:l:p:D:e:M:h" opt; do
    case $opt in
        d) DEVICES="$OPTARG" ;;
        s) BSIZE="$OPTARG" ;;
        l) LOG_DIR="$OPTARG" ;;
        p) PORT="$OPTARG" ;;
        D) DP="$OPTARG" ;;
        e) EXPERT_PER_RANK="$OPTARG" ;;
        M) MAX_MODEL_LEN="$OPTARG" ;;
        h) usage ;;
        \?) echo "无效选项: -$OPTARG" >&2; usage ;;
        :) echo "选项 -$OPTARG 需要参数" >&2; usage ;;
    esac
done

# 设置环境变量
export HCCL_IF_IP=${LOCAL_IP}
export HCCL_SOCKET_IFNAME=${NETWORK_INTERFACE}
export GLOO_SOCKET_IFNAME=${NETWORK_INTERFACE}
export TP_SOCKET_IFNAME=${NETWORK_INTERFACE}
export OMP_PROC_BIND=false
export OMP_NUM_THREADS=10
export PYTORCH_NPU_ALLOC_CONF=expandable_segments:True
export HCCL_BUFFSIZE="$HCCL_BUFFSIZE"
export TASK_QUEUE_ENABLE=1
export HCCL_OP_EXPANSION_MODE="AIV"
export VLLM_USE_V1=1
export ASCEND_RT_VISIBLE_DEVICES=${DEVICES}
export HCCL_EXEC_TIMEOUT=10000
export ASCEND_LAUNCH_BLOCKING=0
export TORCHDYNAMO_VERBOSE=1
export VLLM_ENGINE_ITERATION_TIMEOUT_S=600
export VLLM_LOGGING_LEVEL=INFO

# Profiler环境变量
export VLLM_ASCEND_MODEL_RUNNER_PROFILER_ENABLE=$VLLM_ASCEND_MODEL_RUNNER_PROFILER_ENABLE
export VLLM_ASCEND_MODEL_RUNNER_PROFILER_WAIT=$VLLM_ASCEND_MODEL_RUNNER_PROFILER_WAIT
export VLLM_ASCEND_MODEL_RUNNER_PROFILER_WARMUP=$VLLM_ASCEND_MODEL_RUNNER_PROFILER_WARMUP
export VLLM_ASCEND_MODEL_RUNNER_PROFILER_ACTIVE=$VLLM_ASCEND_MODEL_RUNNER_PROFILER_ACTIVE
export VLLM_ASCEND_MODEL_RUNNER_PROFILER_REPEAT=$VLLM_ASCEND_MODEL_RUNNER_PROFILER_REPEAT
export VLLM_ASCEND_MODEL_RUNNER_PROFILER_SKIP_FIRST=$VLLM_ASCEND_MODEL_RUNNER_PROFILER_SKIP_FIRST
export VLLM_ASCEND_MODEL_RUNNER_PROFILER_DIR="$VLLM_ASCEND_MODEL_RUNNER_PROFILER_DIR"

# 确保日志目录存在
mkdir -p "$LOG_DIR"

# 日志文件名
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
LOG_FILE="$LOG_DIR/decode_only_${DEVICES//,/_}_${TIMESTAMP}.log"
echo "LOG_FILE: $LOG_FILE"

COMPILATION_CONFIG='{"cudagraph_mode": "FULL_DECODE_ONLY", "cudagraph_capture_sizes": ['$BSIZE']}'
echo "BSIZE: $BSIZE"
echo "PORT: $PORT"
echo "DP: $DP"
echo "EXPERT_PER_RANK: $EXPERT_PER_RANK"

# 启动 decode_only 服务
vllm serve "$MODEL_PATH" \
    --host 0.0.0.0 \
    --port "$PORT" \
    --data-parallel-size $DP \
    --tensor-parallel-size $TP \
    --enable-expert-parallel \
    --seed 1024 \
    --max-model-len $MAX_MODEL_LEN \
    --max-num-batched-tokens $BSIZE \
    --max-num-seqs $BSIZE \
    --trust-remote-code \
    --gpu-memory-utilization 0.90 \
    --no-enable-prefix-caching \
    --async-scheduling \
    --additional-config "{\"enable_force_load_balance\": \"True\"}" \
    --kv-transfer-config '{
        "kv_connector": "DecodeBenchConnector",
        "kv_role": "kv_both",
        "kv_connector_extra_config": {
            "fill_mean": 0.015,
            "fill_std": 0.0
        }
    }' \
    --compilation-config "$COMPILATION_CONFIG" \
    2>&1 | tee "$LOG_FILE"
