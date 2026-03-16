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

NODE_SCREEN="${NODE_SCREEN:-bismuth_node}"
POOL_SCREEN="${POOL_SCREEN:-bismuth_pool}"
MINER_SCREEN="${MINER_SCREEN:-bismuth_miner}"

NODE_PORT="${NODE_PORT:-5658}"
POOL_PORT="${POOL_PORT:-8525}"
POOL_HOST="${POOL_HOST:-127.0.0.1}"

# Bismuth timing assumptions
# Обычно блок около 60 сек
TARGET_BLOCK_TIME="${TARGET_BLOCK_TIME:-60}"

NODE_LOG="$LOG_DIR/node.log"
POOL_LOG="$LOG_DIR/pool.log"
MINER_LOG="$LOG_DIR/miner.log"
EVENT_LOG="$LOG_DIR/events.log"
BLOCKS_LOG="$LOG_DIR/blocks_found.log"
BLOCKS_COUNT_FILE="$LOG_DIR/blocks_found.count"

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
    log_event "Screen $name already exists, skipping start"
    return 0
  fi

  log_event "Starting $name"
  screen -dmS "$name" bash -lc "
    cd '$BISMUTH_DIR'
    echo '[\$(date \"+%Y-%m-%d %H:%M:%S\")] START $name' >> '$logfile'
    stdbuf -oL -eL $cmd 2>&1 | tee -a '$logfile'
  "
}

wait_for_port() {
  local host="$1"
  local port="$2"
  local timeout="${3:-120}"
  local waited=0

  log_event "Waiting for $host:$port ..."
  while true; do
    if ss -lntp 2>/dev/null | grep -q ":$port"; then
      log_event "Port $port is listening"
      return 0
    fi

    sleep 2
    waited=$((waited + 2))
    if (( waited >= timeout )); then
      echo "ERROR: timeout waiting for port $port" >&2
      return 1
    fi
  done
}

wait_for_tcp_connect() {
  local host="$1"
  local port="$2"
  local timeout="${3:-120}"
  local waited=0

  log_event "Waiting for TCP connect to $host:$port ..."
  while true; do
    if nc -z "$host" "$port" >/dev/null 2>&1; then
      log_event "TCP connect to $host:$port succeeded"
      return 0
    fi

    sleep 2
    waited=$((waited + 2))
    if (( waited >= timeout )); then
      echo "ERROR: timeout waiting for TCP connect to $host:$port" >&2
      return 1
    fi
  done
}

print_section() {
  echo
  echo "==================== $* ===================="
}

# =========================
# Hashrate parsing
# =========================
extract_latest_hashrate_raw() {
  grep -Eo '[0-9]+([.][0-9]+)?[[:space:]]*(Mh/s|MH/s|Gh/s|GH/s)' "$MINER_LOG" 2>/dev/null | tail -n 1 || true
}

# Нормализуем в H/s
# В вашем kbkminer выводит "Mh/s", но по факту это ближе к MH/s.
# Поэтому:
#   Mh/s/MH/s -> *1e6
#   Gh/s/GH/s -> *1e9
extract_latest_hashrate_hs() {
  local raw unit value
  raw="$(extract_latest_hashrate_raw)"
  if [[ -z "${raw:-}" ]]; then
    echo ""
    return 0
  fi

  value="$(echo "$raw" | awk '{print $1}')"
  unit="$(echo "$raw" | awk '{print $2}')"

  python3 - <<PY
value=float("$value")
unit="$unit".lower()
if unit == "mh/s":
    print(value * 1_000_000)
elif unit == "gh/s":
    print(value * 1_000_000_000)
else:
    print("")
PY
}

format_hs_human() {
  local hs="${1:-}"
  if [[ -z "${hs:-}" ]]; then
    echo "N/A"
    return 0
  fi

  python3 - <<PY
hs=float("$hs")
if hs >= 1_000_000_000:
    print(f"{hs/1_000_000_000:.3f} GH/s")
elif hs >= 1_000_000:
    print(f"{hs/1_000_000:.3f} MH/s")
elif hs >= 1_000:
    print(f"{hs/1_000:.3f} kH/s")
else:
    print(f"{hs:.3f} H/s")
PY
}

# =========================
# Difficulty / network hashrate
# =========================
extract_latest_difficulty() {
  grep -Eo 'difficulty[^0-9]*[0-9]+([.][0-9]+)?' "$NODE_LOG" 2>/dev/null | tail -n 1 | grep -Eo '[0-9]+([.][0-9]+)?' || true
}

# Network hashrate estimate:
# hashrate ~= difficulty * 2^32 / block_time
estimate_network_hashrate_hs() {
  local diff="${1:-}"
  if [[ -z "${diff:-}" ]]; then
    echo ""
    return 0
  fi

  python3 - <<PY
difficulty=float("$diff")
block_time=float("$TARGET_BLOCK_TIME")
network_hs = difficulty * (2**32) / block_time
print(network_hs)
PY
}

# ETA = network_hashrate / your_hashrate * block_time
estimate_eta_seconds() {
  local your_hs="${1:-}"
  local network_hs="${2:-}"

  if [[ -z "${your_hs:-}" || -z "${network_hs:-}" ]]; then
    echo ""
    return 0
  fi

  python3 - <<PY
your_hs=float("$your_hs")
network_hs=float("$network_hs")
block_time=float("$TARGET_BLOCK_TIME")
if your_hs <= 0:
    print("")
else:
    eta = (network_hs / your_hs) * block_time
    print(eta)
PY
}

format_duration_human() {
  local secs="${1:-}"
  if [[ -z "${secs:-}" ]]; then
    echo "N/A"
    return 0
  fi

  python3 - <<PY
secs=float("$secs")
mins=secs/60
hours=secs/3600
days=secs/86400
if secs < 60:
    print(f"{secs:.0f} sec")
elif mins < 60:
    print(f"{mins:.1f} min")
elif hours < 24:
    print(f"{hours:.2f} h")
else:
    print(f"{days:.2f} d")
PY
}

# =========================
# Block detection
# =========================
init_block_counter() {
  [[ -f "$BLOCKS_COUNT_FILE" ]] || echo "0" > "$BLOCKS_COUNT_FILE"
  [[ -f "$BLOCKS_LOG" ]] || : > "$BLOCKS_LOG"
}

get_blocks_count() {
  cat "$BLOCKS_COUNT_FILE" 2>/dev/null || echo "0"
}

increment_blocks_count() {
  local current
  current="$(get_blocks_count)"
  current=$((current + 1))
  echo "$current" > "$BLOCKS_COUNT_FILE"
}

# Ищем возможные фразы найденного блока
# Можно дополнять список паттернов
scan_new_found_blocks() {
  local tmpfile last_matches new_count
  tmpfile="$(mktemp)"

  grep -Ei 'block found|found block|won block|solved block|new block found|candidate accepted|share accepted.*block|accepted.*block' \
    "$POOL_LOG" "$NODE_LOG" 2>/dev/null > "$tmpfile" || true

  if [[ ! -s "$tmpfile" ]]; then
    rm -f "$tmpfile"
    return 0
  fi

  if [[ ! -f "$BLOCKS_LOG" ]]; then
    : > "$BLOCKS_LOG"
  fi

  # дописываем только новые строки
  while IFS= read -r line; do
    if ! grep -Fqx "$line" "$BLOCKS_LOG" 2>/dev/null; then
      echo "$line" >> "$BLOCKS_LOG"
      increment_blocks_count
      log_event "BLOCK FOUND detected: $line"
    fi
  done < "$tmpfile"

  rm -f "$tmpfile"
}

# =========================
# Log extracts
# =========================
extract_latest_blockline() {
  grep -Ei 'Last block|block found|Found block|Generated block|Blockhash|Consensus height|Work package sent' \
    "$NODE_LOG" "$POOL_LOG" "$MINER_LOG" 2>/dev/null | tail -n 12 || true
}

extract_pool_activity() {
  grep -Ei 'share|accepted|getwork|worker|solution|blockhash|difficulty|connected|Work package sent|Error' \
    "$POOL_LOG" 2>/dev/null | tail -n 20 || true
}

extract_node_status() {
  grep -Ei 'Consensus height|Last block|Known Peers|Number of Outbound connections|Total number of nodes|MEMPOOL|Local address|Testing peers|difficulty' \
    "$NODE_LOG" 2>/dev/null | tail -n 20 || true
}

extract_miner_activity() {
  grep -Ei 'searching for solutions|Updated CUDA block hash|Mh/s|MH/s|Gh/s|GH/s|miner|Loading heavy3a.bin|Socket EOF|Unable to connect' \
    "$MINER_LOG" 2>/dev/null | tail -n 20 || true
}

print_gpu_status() {
  if command -v nvidia-smi >/dev/null 2>&1; then
    nvidia-smi \
      --query-gpu=index,name,utilization.gpu,temperature.gpu,power.draw,memory.used,memory.total \
      --format=csv,noheader,nounits 2>/dev/null || true
  else
    echo "nvidia-smi not found"
  fi
}

print_processes() {
  ps -eo pid,etime,cmd | grep -E 'python3 (node\.py|optipoolware\.py|optihash\.py)' | grep -v grep || true
}

print_ports() {
  ss -lntp 2>/dev/null | grep -E "(:${NODE_PORT}|:${POOL_PORT})" || true
}

# =========================
# Checks
# =========================
require_file "$BISMUTH_DIR/node.py"
require_file "$BISMUTH_DIR/optipoolware.py"
require_file "$BISMUTH_DIR/optihash.py"

# =========================
# Safe cleanup
# =========================
log_event "Stopping old Bismuth processes and Bismuth screen sessions only"

pkill -f optihash.py || true
pkill -f optipoolware.py || true
pkill -f 'python3 node.py' || true

screen -S "$MINER_SCREEN" -X quit || true
screen -S "$POOL_SCREEN" -X quit || true
screen -S "$NODE_SCREEN" -X quit || true

screen -wipe >/dev/null 2>&1 || true
sleep 2

# =========================
# Clear old logs
# =========================
: > "$NODE_LOG"
: > "$POOL_LOG"
: > "$MINER_LOG"
: > "$EVENT_LOG"
: > "$BLOCKS_LOG"
echo "0" > "$BLOCKS_COUNT_FILE"

log_event "Old logs cleared"
init_block_counter

# =========================
# Start node and wait
# =========================
start_in_screen "$NODE_SCREEN" "$NODE_CMD" "$NODE_LOG"
wait_for_port "0.0.0.0" "$NODE_PORT" 180

# =========================
# Start pool and wait
# =========================
start_in_screen "$POOL_SCREEN" "$POOL_CMD" "$POOL_LOG"
wait_for_port "0.0.0.0" "$POOL_PORT" 180
wait_for_tcp_connect "$POOL_HOST" "$POOL_PORT" 180

# small extra delay so pool is not just listening but already serving getwork
sleep 5

# =========================
# Start miner
# =========================
start_in_screen "$MINER_SCREEN" "$MINER_CMD" "$MINER_LOG"

log_event "All services started successfully"

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
  scan_new_found_blocks

  YOUR_HS_RAW="$(extract_latest_hashrate_raw)"
  YOUR_HS="$(extract_latest_hashrate_hs)"
  YOUR_HS_HUMAN="$(format_hs_human "$YOUR_HS")"

  DIFF="$(extract_latest_difficulty)"
  NETWORK_HS="$(estimate_network_hashrate_hs "$DIFF")"
  NETWORK_HS_HUMAN="$(format_hs_human "$NETWORK_HS")"

  ETA_SECS="$(estimate_eta_seconds "$YOUR_HS" "$NETWORK_HS")"
  ETA_HUMAN="$(format_duration_human "$ETA_SECS")"

  BLOCKS_COUNT="$(get_blocks_count)"

  clear
  echo "Bismuth monitor  |  $(ts)"
  echo "Bismuth dir: $BISMUTH_DIR"
  echo "Logs dir:    $LOG_DIR"
  echo "Interval:    ${MONITOR_INTERVAL}s"

  print_section "MINING SUMMARY"
  echo "Your hashrate (raw):     ${YOUR_HS_RAW:-N/A}"
  echo "Your hashrate (parsed):  ${YOUR_HS_HUMAN}"
  echo "Difficulty:              ${DIFF:-N/A}"
  echo "Network hashrate est.:   ${NETWORK_HS_HUMAN}"
  echo "Estimated time/block:    ${ETA_HUMAN}"
  echo "Blocks found count:      ${BLOCKS_COUNT}"
  echo "Blocks log file:         ${BLOCKS_LOG}"

  print_section "PROCESSES"
  print_processes

  print_section "PORTS"
  print_ports

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
  echo "  tail -f $BLOCKS_LOG"
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