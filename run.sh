#!/usr/bin/env bash
set -Eeuo pipefail

# =========================
# Bismuth paths and settings
# =========================
BISMUTH_DIR="${BISMUTH_DIR:-$HOME/Bismuth}"
LOG_DIR="${LOG_DIR:-$BISMUTH_DIR/logs}"
MONITOR_INTERVAL="${MONITOR_INTERVAL:-10}"

NODE_CMD="${NODE_CMD:-python3 node.py}"
POOL_CMD="${POOL_CMD:-python3 optipoolware.py}"
MINER_CMD="${MINER_CMD:-python3 optihash.py}"

# Screen session names
NODE_SCREEN="${NODE_SCREEN:-bismuth_node}"
POOL_SCREEN="${POOL_SCREEN:-bismuth_pool}"
MINER_SCREEN="${MINER_SCREEN:-bismuth_miner}"

# Log files
NODE_LOG="$LOG_DIR/node.log"
POOL_LOG="$LOG_DIR/pool.log"
MINER_LOG="$LOG_DIR/miner.log"
EVENT_LOG="$LOG_DIR/events.log"

mkdir -p "$LOG_DIR"

# =========================
# Helpers
# =========================
ts() {
  date "+%Y-%m-%d %H:%M:%S"
}

log_event() {
  echo "[$(ts)] $*" | tee -a "$EVENT_LOG"
}

require_file() {
  local f="$1"
  if [[ ! -e "$f" ]]; then
    echo "ERROR: file not found: $f" >&2
    exit 1
  fi
}

screen_exists() {
  local name="$1"
  screen -ls 2>/dev/null | grep -q "[[:space:]]${name}[[:space:]]"
}

start_in_screen() {
  local name="$1"
  local cmd="$2"
  local logfile="$3"

  if screen_exists "$name"; then
    log_event "Screen $name already exists, skip start"
    return 0
  fi

  log_event "Starting $name"
  screen -dmS "$name" bash -lc "
    cd '$BISMUTH_DIR'
    echo '[\$(date \"+%Y-%m-%d %H:%M:%S\")] START $name' >> '$logfile'
    stdbuf -oL -eL $cmd 2>&1 | tee -a '$logfile'
  "
}

print_section() {
  echo
  echo "==================== $* ===================="
}

extract_latest_hashrate() {
  grep -Eo '[0-9]+([.][0-9]+)?[[:space:]]*(Mh/s|MH/s|Gh/s|GH/s)' "$MINER_LOG" 2>/dev/null | tail -n 1 || true
}

extract_latest_blockline() {
  grep -Ei 'Last block|block found|Found block|Generated block|Blockhash|Consensus height' "$NODE_LOG" "$POOL_LOG" "$MINER_LOG" 2>/dev/null | tail -n 8 || true
}

extract_pool_activity() {
  grep -Ei 'share|accepted|getwork|worker|solution|blockhash|difficulty|connected' "$POOL_LOG" 2>/dev/null | tail -n 15 || true
}

extract_node_status() {
  grep -Ei 'Consensus height|Last block|Known Peers|Number of Outbound connections|Total number of nodes|MEMPOOL|Local address' "$NODE_LOG" 2>/dev/null | tail -n 15 || true
}

extract_miner_activity() {
  grep -Ei 'searching for solutions|Updated CUDA block hash|Mh/s|MH/s|Gh/s|GH/s|miner|Loading heavy3a.bin' "$MINER_LOG" 2>/dev/null | tail -n 15 || true
}

print_gpu_status() {
  if command -v nvidia-smi >/dev/null 2>&1; then
    nvidia-smi --query-gpu=index,name,utilization.gpu,temperature.gpu,power.draw,memory.used,memory.total --format=csv,noheader,nounits 2>/dev/null || true
  else
    echo "nvidia-smi not found"
  fi
}

print_processes() {
  ps -eo pid,etime,cmd | grep -E 'python3 (node\.py|optipoolware\.py|optihash\.py)' | grep -v grep || true
}

print_ports() {
  ss -lntp 2>/dev/null | grep -E '(:5658|:8525)' || true
}

# =========================
# Checks
# =========================
require_file "$BISMUTH_DIR/node.py"
require_file "$BISMUTH_DIR/optipoolware.py"
require_file "$BISMUTH_DIR/optihash.py"

# =========================
# Full cleanup before start
# =========================
log_event "Stopping old Bismuth processes and cleaning old screen sessions"
pkill -f optihash.py || true
pkill -f optipoolware.py || true
pkill -f node.py || true
killall screen || true
screen -wipe >/dev/null 2>&1 || true

sleep 2

# =========================
# Start services
# =========================
start_in_screen "$NODE_SCREEN" "$NODE_CMD" "$NODE_LOG"
sleep 5
start_in_screen "$POOL_SCREEN" "$POOL_CMD" "$POOL_LOG"
sleep 3
start_in_screen "$MINER_SCREEN" "$MINER_CMD" "$MINER_LOG"
sleep 3

log_event "All start commands issued"

# =========================
# Signal handling
# =========================
cleanup() {
  echo
  log_event "Monitor stopped by user"
  echo "Monitor stopped. Processes continue running in screen sessions:"
  echo "  $NODE_SCREEN"
  echo "  $POOL_SCREEN"
  echo "  $MINER_SCREEN"
  echo
  echo "Attach commands:"
  echo "  screen -r $NODE_SCREEN"
  echo "  screen -r $POOL_SCREEN"
  echo "  screen -r $MINER_SCREEN"
}
trap cleanup INT TERM

# =========================
# Monitor loop
# =========================
while true; do
  clear
  echo "Bismuth monitor  |  $(ts)"
  echo "Bismuth dir: $BISMUTH_DIR"
  echo "Logs dir:    $LOG_DIR"
  echo "Interval:    ${MONITOR_INTERVAL}s"

  print_section "PROCESSES"
  print_processes

  print_section "PORTS"
  print_ports

  print_section "LATEST HASHRATE"
  HR="$(extract_latest_hashrate)"
  if [[ -n "${HR:-}" ]]; then
    echo "$HR"
  else
    echo "No hashrate line found yet"
  fi

  print_section "NODE STATUS"
  extract_node_status

  print_section "POOL ACTIVITY"
  extract_pool_activity

  print_section "MINER ACTIVITY"
  extract_miner_activity

  print_section "RECENT BLOCK / HASH LINES"
  extract_latest_blockline

  print_section "GPU STATUS"
  print_gpu_status

  print_section "SCREEN SESSIONS"
  screen -ls 2>/dev/null || true

  echo
  echo "Live logs:"
  echo "  tail -f $NODE_LOG"
  echo "  tail -f $POOL_LOG"
  echo "  tail -f $MINER_LOG"
  echo
  echo "Attach:"
  echo "  screen -r $NODE_SCREEN"
  echo "  screen -r $POOL_SCREEN"
  echo "  screen -r $MINER_SCREEN"
  echo
  echo "Stop only monitor: Ctrl+C"
  echo "Stop services manually:"
  echo "  screen -S $MINER_SCREEN -X quit"
  echo "  screen -S $POOL_SCREEN -X quit"
  echo "  screen -S $NODE_SCREEN -X quit"

  sleep "$MONITOR_INTERVAL"
done