#!/usr/bin/env bash
set -euo pipefail

# -----------------------------
# 配置项
# -----------------------------
RPC_URL="${RPC_URL:-http://localhost:8545}"
EXPECTED_CHAIN_ID="${EXPECTED_CHAIN_ID:-20260}"
DEPLOYER_ADDR="${DEPLOYER_ADDR:-0x148dd37731e3CaA6d7C0DcF6B89372e5aF135D0a}"
EXPECTED_BALANCE_ETH="${EXPECTED_BALANCE_ETH:-1000}"
MAX_WAIT_SECONDS="${MAX_WAIT_SECONDS:-120}"            # 最大等待时长
CHECK_INTERVAL="${CHECK_INTERVAL:-5}"                  # 检查间隔（秒）
MIN_PEERS="${MIN_PEERS:-3}"                            # 节点最小连接数
DATA_DIR="${DATA_DIR:-data}"                           # 链数据目录（宿主机）

# -----------------------------
# 颜色 & 格式控制
# -----------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'
CLEAR_LINE='\033[K'

# -----------------------------
# 依赖检查
# -----------------------------
need_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo -e "${RED}❌ 缺少依赖命令: $1${NC}"
    exit 1
  fi
}
need_cmd docker
need_cmd curl
need_cmd jq
need_cmd python3

# -----------------------------
# JSON-RPC Helper
# -----------------------------
rpc_call() {
  local method="$1"
  local params="${2:-[]}"
  # 增加 --max-time 防止网络请求无限挂起
  curl -s --max-time 5 -X POST "${RPC_URL}" \
    -H "Content-Type: application/json" \
    --data "{\"jsonrpc\":\"2.0\",\"method\":\"${method}\",\"params\":${params},\"id\":1}" 2>/dev/null || echo '{"error":"connection_failed"}'
}

hex_to_dec() {
  local hex="$1"
  if [[ "$hex" == "null" ]] || [[ -z "$hex" ]] || [[ "$hex" == *"error"* ]]; then
    echo "0"
    return
  fi
  # 处理可能的 0x 前缀
  python3 -c "print(int('${hex}', 16))" 2>/dev/null || echo "0"
}

# 修复 unbound variable
# 在主作用域预先定义，防止 set -u 报错
CHAIN_READY=false

# -----------------------------
# 等待链就绪函数
# -----------------------------
wait_for_chain() {
  echo -e "${YELLOW}⏳ 等待创世块生成和节点互联 (最多 ${MAX_WAIT_SECONDS} 秒)...${NC}"
  echo -e "${BLUE}   (每隔 ${CHECK_INTERVAL} 秒检测一次状态)${NC}"
  
  local elapsed=0
  local ready=false
  local last_block="?"
  local last_peers="?"

  while [ $elapsed -lt $MAX_WAIT_SECONDS ]; do
    # 1. 检查 RPC 是否通
    local raw_block
    raw_block=$(rpc_call eth_blockNumber)
    local block_hex
    block_hex=$(echo "$raw_block" | jq -r '.result // empty' 2>/dev/null)
    
    local current_peers=0
    local current_block_dec=0

    if [ -n "$block_hex" ] && [ "$block_hex" != "null" ] && [ "$block_hex" != "" ]; then
      current_block_dec=$(hex_to_dec "$block_hex")
      last_block="$current_block_dec"

      # 2. 检查连接数
      local raw_peer
      raw_peer=$(rpc_call net_peerCount)
      local peer_hex
      peer_hex=$(echo "$raw_peer" | jq -r '.result // empty' 2>/dev/null)
      
      if [ -n "$peer_hex" ] && [ "$peer_hex" != "null" ] && [ "$peer_hex" != "" ]; then
        current_peers=$(hex_to_dec "$peer_hex")
        last_peers="$current_peers"
      fi
    else
      last_block="RPC Fail"
    fi

    # ✅ 判断成功条件
    if [ "$current_peers" -ge "$MIN_PEERS" ]; then
      echo "" # 换行
      echo -e "${GREEN}✅ 链已就绪！区块高度: ${last_block}, 连接数: ${last_peers}/${MIN_PEERS} (耗时: ${elapsed}s)${NC}"
      ready=true
      CHAIN_READY=true
      break
    fi

    # 🖨️ 打印进度 (每次循环都打印，间隔设为 5 秒)
    # 使用 printf 格式化对齐
    printf "\r   ⏳ 检查中... 区块: %-5s | 节点: %s/%s | 已等待: %ds${CLEAR_LINE}" "$last_block" "$last_peers" "$MIN_PEERS" "$elapsed"
    
    sleep "$CHECK_INTERVAL"
    elapsed=$((elapsed + CHECK_INTERVAL))
  done
  
  # 换行
  echo ""

  if [ "$ready" = false ]; then
    echo -e "${RED}❌ 超时：在 ${MAX_WAIT_SECONDS} 秒内未能满足启动条件 (连接数 >= ${MIN_PEERS})${NC}"
    echo -e "${YELLOW}💡 诊断建议:${NC}"
    echo "   1. 运行 'docker compose logs --tail=50' 查看节点报错"
    echo "   2. 检查端口冲突: 'netstat -tlnp | grep 8545'"
  fi
}

# -----------------------------
# 主流程
# -----------------------------
echo -e "${YELLOW}🛑 正在停止容器...${NC}"
docker compose down

echo -e "${YELLOW}🗑️  正在删除链数据 (保留私钥和配置)...${NC}"

if [ -d "${DATA_DIR}/" ]; then
  sudo chown -R "$USER:$USER" "${DATA_DIR}/" >/dev/null 2>&1 || true
  rm -rf "${DATA_DIR}/"
  echo -e "${GREEN}✅ 数据目录已清除: ${DATA_DIR}/ ${NC}"
else
  echo -e "${YELLOW}⚠️  数据目录不存在，跳过删除: ${DATA_DIR}/ ${NC}"
fi

echo -e "${YELLOW}🚀 正在启动全新链...${NC}"
docker compose up -d

# 等待
wait_for_chain

echo "----------------------------------------"
echo -e "${YELLOW}🔍 执行最终状态验证...${NC}"

# 1) 检查区块高度
BLOCK_HEX="$(rpc_call eth_blockNumber | jq -r .result)"
if [ "${BLOCK_HEX}" != "null" ] && [ -n "${BLOCK_HEX}" ]; then
  BLOCK_DEC="$(hex_to_dec "${BLOCK_HEX}")"
  echo -e "📦 区块高度 (eth_blockNumber): ${GREEN}${BLOCK_DEC}${NC}"
  echo -e "   ✅ 链已启动"
else
  echo -e "📦 区块高度: ${RED}获取失败 (RPC 可能未响应)${NC}"
fi

# 2) 检查 Chain ID
CHAIN_HEX="$(rpc_call eth_chainId | jq -r .result)"
if [ "${CHAIN_HEX}" != "null" ] && [ -n "${CHAIN_HEX}" ]; then
  CHAIN_DEC="$(hex_to_dec "${CHAIN_HEX}")"
  echo -e "🆔 链 ID (eth_chainId): ${GREEN}${CHAIN_DEC}${NC}"
  if [ "${CHAIN_DEC}" -eq "${EXPECTED_CHAIN_ID}" ]; then
    echo -e "   ✅ ID 匹配配置 (${EXPECTED_CHAIN_ID})"
  else
    echo -e "   ${RED}⚠️  ID 不匹配预期值 ${EXPECTED_CHAIN_ID}${NC}"
  fi
else
  echo -e "🆔 链 ID: ${RED}获取失败${NC}"
fi

# 3) 检查节点连接数
PEER_HEX="$(rpc_call net_peerCount | jq -r .result)"
if [ "${PEER_HEX}" != "null" ] && [ -n "${PEER_HEX}" ]; then
  PEER_DEC="$(hex_to_dec "${PEER_HEX}")"
  echo -e "🔗 连接节点数 (net_peerCount): ${GREEN}${PEER_DEC}${NC}"
  if [ "${PEER_DEC}" -ge "${MIN_PEERS}" ]; then
    echo -e "   ✅ 网络健康 (4 节点网络需至少 ${MIN_PEERS} 个连接)"
  else
    echo -e "   ${YELLOW}⚠️  连接数不足 (当前: ${PEER_DEC}, 期望: ≥${MIN_PEERS})${NC}"
  fi
else
  echo -e "🔗 连接节点数: ${RED}获取失败${NC}"
fi

# 4) 检查部署者初始余额
BALANCE_HEX="$(rpc_call eth_getBalance "[\"${DEPLOYER_ADDR}\",\"latest\"]" | jq -r .result)"
if [ "${BALANCE_HEX}" != "null" ] && [ -n "${BALANCE_HEX}" ]; then
  python3 - <<PY
bal_hex = "${BALANCE_HEX}"
addr = "${DEPLOYER_ADDR}"
try:
    bal = int(bal_hex, 16)
    expected_eth = int("${EXPECTED_BALANCE_ETH}")
    expected = expected_eth * 10**18
    eth = bal / 10**18
    print(f"💰 部署者余额 ({addr}): {eth:.6f} ETH")
    if bal == expected:
        print(f"   ✅ 余额正确 ({expected_eth} ETH)")
    else:
        print(f"   ⚠️  余额与预期 {expected_eth} ETH 不符")
    print(f"   (hex={bal_hex}, wei={bal})")
except Exception as e:
    print(f"   ${RED}解析错误: {e}${NC}")
PY
else
  echo -e "💰 部署者余额: ${RED}获取失败${NC}"
fi

echo "----------------------------------------"
if [ "$CHAIN_READY" = true ]; then
    echo -e "${GREEN}✅ 链重置完成！${NC}"
    echo -e "💡 提示：请记得重新运行 Hardhat 部署脚本以部署新合约。"
else
    echo -e "${YELLOW}⚠️ 链重置完成但状态未完全达标，请检查上述警告。${NC}"
fi