#!/usr/bin/with-contenv bashio

set -u
set -o pipefail

SSH_HOST=$(bashio::config 'ssh_host')
SSH_PORT=$(bashio::config 'ssh_port')
SSH_USER=$(bashio::config 'ssh_user')
REMOTE_PORT=$(bashio::config 'remote_port')

SSH_DIR="/root/.ssh"
SSH_KEY_PATH="${SSH_DIR}/id_rsa"
KNOWN_HOSTS_PATH="${SSH_DIR}/known_hosts"
CONTROL_SOCKET="/tmp/callhome-control.sock"
SSH_TARGET="${SSH_USER}@${SSH_HOST}"
HEALTH_CHECK_INTERVAL=60
HEALTH_LOG_INTERVAL=60
REBUILD_INTERVAL=$((12 * 60 * 60))

AUTOSSH_PID=""
LAST_REBUILD_TS=0
HEALTH_CHECK_COUNT=0
HEALTH_FAILURE_REASON=""
REMOTE_LISTENER_CHECK_ENABLED=1
UPDATE_SERVER_PID=""

SSH_OPTIONS=(
    -p "${SSH_PORT}"
    -i "${SSH_KEY_PATH}"
    -o ExitOnForwardFailure=yes
    -o ServerAliveInterval=30
    -o ServerAliveCountMax=3
    -o TCPKeepAlive=yes
    -o BatchMode=yes
    -o StrictHostKeyChecking=no
    -o UserKnownHostsFile="${KNOWN_HOSTS_PATH}"
    -o ConnectTimeout=15
)

log_info() {
    bashio::log.info "$*"
}

log_warn() {
    bashio::log.warning "$*"
}

log_error() {
    bashio::log.error "$*"
}

start_update_server() {
    case "${UPDATE_UI_ENABLED}" in
        true|True|TRUE|1|yes|Yes|on|On)
            ;;
        *)
            log_info "Update UI is disabled."
            return 0
            ;;
    esac

    if [ "${INGRESS_PORT}" = "" ]; then
        INGRESS_PORT=8099
    fi

    if ! command -v python3 >/dev/null 2>&1; then
        log_warn "python3 is not available. Update UI will not start."
        return 0
    fi

    log_info "Starting update UI on ingress port ${INGRESS_PORT}."
    INGRESS_PORT="${INGRESS_PORT}" python3 /update_server.py &
    UPDATE_SERVER_PID=$!
}

stop_update_server() {
    if [ -n "${UPDATE_SERVER_PID}" ] && kill -0 "${UPDATE_SERVER_PID}" 2>/dev/null; then
        kill "${UPDATE_SERVER_PID}" 2>/dev/null || true
        wait "${UPDATE_SERVER_PID}" 2>/dev/null || true
    fi

    UPDATE_SERVER_PID=""
}

run_with_timeout() {
    local seconds="$1"
    shift

    if command -v timeout >/dev/null 2>&1; then
        timeout "${seconds}" "$@"
    else
        "$@"
    fi
}

is_tunnel_running() {
    [ -n "${AUTOSSH_PID}" ] && kill -0 "${AUTOSSH_PID}" 2>/dev/null
}

prepare_ssh_key() {
    local raw_key
    local clean_base64

    mkdir -p "${SSH_DIR}"
    chmod 700 "${SSH_DIR}"

    log_info "Retrieving and restoring SSH private key."

    raw_key=$(jq -r '.private_key' /data/options.json)
    clean_base64=$(printf '%s' "${raw_key}" | sed 's/-----BEGIN [A-Z ]*-----//g' | sed 's/-----END [A-Z ]*-----//g' | tr -d '[:space:]')

    {
        echo "-----BEGIN OPENSSH PRIVATE KEY-----"
        printf '%s\n' "${clean_base64}" | fold -w 64
        echo "-----END OPENSSH PRIVATE KEY-----"
    } > "${SSH_KEY_PATH}"

    chmod 600 "${SSH_KEY_PATH}"

    if ! ssh-keygen -l -f "${SSH_KEY_PATH}" >/dev/null 2>&1; then
        log_error "Private key remains invalid after repair attempt."
        exit 1
    fi

    touch "${KNOWN_HOSTS_PATH}"
    chmod 600 "${KNOWN_HOSTS_PATH}"

    log_info "SSH private key loaded successfully."
}

refresh_known_hosts() {
    log_info "Fetching SSH host key for ${SSH_HOST}:${SSH_PORT}."

    if ! ssh-keyscan -H -p "${SSH_PORT}" "${SSH_HOST}" >> "${KNOWN_HOSTS_PATH}" 2>/dev/null; then
        log_warn "Could not pre-fetch host key. Proceeding with StrictHostKeyChecking=no."
    fi
}

stop_tunnel() {
    if [ -S "${CONTROL_SOCKET}" ]; then
        run_with_timeout 5 ssh -S "${CONTROL_SOCKET}" -O exit -p "${SSH_PORT}" "${SSH_TARGET}" >/dev/null 2>&1 || true
    fi

    if is_tunnel_running; then
        log_info "Stopping existing reverse tunnel with PID ${AUTOSSH_PID}."
        kill "${AUTOSSH_PID}" 2>/dev/null || true

        for ((i = 0; i < 10; i++)); do
            if ! is_tunnel_running; then
                break
            fi
            sleep 1
        done

        if is_tunnel_running; then
            log_warn "Tunnel process did not respond to SIGTERM, forcing stop."
            kill -9 "${AUTOSSH_PID}" 2>/dev/null || true
        fi

        wait "${AUTOSSH_PID}" 2>/dev/null || true
    fi

    AUTOSSH_PID=""
    rm -f "${CONTROL_SOCKET}"
}

start_tunnel() {
    rm -f "${CONTROL_SOCKET}"

    export AUTOSSH_GATETIME=0

    log_info "Starting reverse SSH tunnel to ${SSH_HOST}:${SSH_PORT} with remote port ${REMOTE_PORT}."

    autossh -M 0 \
        "${SSH_OPTIONS[@]}" \
        -o ControlMaster=yes \
        -o ControlPersist=yes \
        -o ControlPath="${CONTROL_SOCKET}" \
        -N -R "${REMOTE_PORT}:homeassistant:8123" "${SSH_TARGET}" &

    AUTOSSH_PID=$!
    LAST_REBUILD_TS=$(date +%s)

    sleep 3

    if ! is_tunnel_running; then
        wait "${AUTOSSH_PID}" 2>/dev/null || true
        log_error "Tunnel process stopped immediately after starting."
        AUTOSSH_PID=""
        return 1
    fi

    log_info "Reverse SSH tunnel started with PID ${AUTOSSH_PID}."
    return 0
}

check_control_connection() {
    if [ ! -S "${CONTROL_SOCKET}" ]; then
        HEALTH_FAILURE_REASON="control socket is missing"
        return 1
    fi

    if ! ssh -S "${CONTROL_SOCKET}" -O check -p "${SSH_PORT}" "${SSH_TARGET}" >/dev/null 2>&1; then
        HEALTH_FAILURE_REASON="SSH control connection is not active"
        return 1
    fi

    if ! run_with_timeout 20 ssh -S "${CONTROL_SOCKET}" -o ControlMaster=no -o ControlPath="${CONTROL_SOCKET}" -o BatchMode=yes -p "${SSH_PORT}" "${SSH_TARGET}" exit >/dev/null 2>&1; then
        HEALTH_FAILURE_REASON="existing SSH connection is no longer responding"
        return 1
    fi

    return 0
}

check_remote_listener() {
    local remote_check
    local status

    if [ "${REMOTE_LISTENER_CHECK_ENABLED}" -ne 1 ]; then
        return 0
    fi

    remote_check="if command -v ss >/dev/null 2>&1; then ss -ltnH '( sport = :${REMOTE_PORT} )' | grep -q .; elif command -v netstat >/dev/null 2>&1; then netstat -ltn 2>/dev/null | grep -qE '[:.]${REMOTE_PORT}[[:space:]]'; elif command -v lsof >/dev/null 2>&1; then lsof -nP -iTCP:${REMOTE_PORT} -sTCP:LISTEN >/dev/null 2>&1; elif command -v nc >/dev/null 2>&1; then nc -z 127.0.0.1 ${REMOTE_PORT} >/dev/null 2>&1; else exit 3; fi"

    run_with_timeout 20 ssh "${SSH_OPTIONS[@]}" "${SSH_TARGET}" "${remote_check}" >/dev/null 2>&1
    status=$?

    if [ "${status}" -eq 0 ]; then
        return 0
    fi

    if [ "${status}" -eq 3 ]; then
        log_warn "Remote host does not support ss, netstat, lsof, or nc. Listener check disabled; SSH health probe remains active."
        REMOTE_LISTENER_CHECK_ENABLED=0
        return 0
    fi

    HEALTH_FAILURE_REASON="remote port ${REMOTE_PORT} is no longer listening on ${SSH_HOST}"
    return 1
}

probe_tunnel_health() {
    HEALTH_FAILURE_REASON=""

    if ! is_tunnel_running; then
        HEALTH_FAILURE_REASON="autossh process is not running"
        return 1
    fi

    check_control_connection || return 1
    check_remote_listener || return 1

    return 0
}

wait_for_healthy_tunnel() {
    local attempt

    for ((attempt = 1; attempt <= 10; attempt++)); do
        if probe_tunnel_health; then
            return 0
        fi

        log_warn "Tunnel not yet healthy after start (attempt ${attempt}/10): ${HEALTH_FAILURE_REASON}."
        sleep 3
    done

    return 1
}

rebuild_tunnel() {
    local reason="$1"

    log_warn "Rebuilding reverse SSH tunnel: ${reason}."
    stop_tunnel

    if ! start_tunnel; then
        log_error "Rebuild of reverse tunnel failed during startup."
        return 1
    fi

    if ! wait_for_healthy_tunnel; then
        log_error "Rebuilt tunnel did not become healthy: ${HEALTH_FAILURE_REASON}."
        return 1
    fi

    log_info "Reverse SSH tunnel rebuilt and healthy."
    return 0
}

shutdown() {
    log_info "Shutdown signal received, closing reverse tunnel."
    stop_update_server
    stop_tunnel
    exit 0
}

trap shutdown SIGINT SIGTERM SIGHUP

prepare_ssh_key
refresh_known_hosts
UPDATE_UI_ENABLED=$(bashio::config 'update_ui')
INGRESS_PORT=${INGRESS_PORT:-8099}
start_update_server

if ! start_tunnel; then
    stop_update_server
    exit 1
fi

if ! wait_for_healthy_tunnel; then
    log_error "Initial reverse tunnel did not become healthy: ${HEALTH_FAILURE_REASON}."
    stop_update_server
    exit 1
fi

log_info "Health checks active: every ${HEALTH_CHECK_INTERVAL}s. Forced rebuild every 12 hours."

while true; do
    sleep "${HEALTH_CHECK_INTERVAL}"

    if ! probe_tunnel_health; then
        log_warn "Health check failed: ${HEALTH_FAILURE_REASON}."
        rebuild_tunnel "health check failed" || {
            stop_update_server
            exit 1
        }
        HEALTH_CHECK_COUNT=0
        continue
    fi

    HEALTH_CHECK_COUNT=$((HEALTH_CHECK_COUNT + 1))

    if [ $((HEALTH_CHECK_COUNT % HEALTH_LOG_INTERVAL)) -eq 0 ]; then
        log_info "Health check successful: reverse SSH tunnel is still active."
    fi

    if [ $(( $(date +%s) - LAST_REBUILD_TS )) -ge "${REBUILD_INTERVAL}" ]; then
        log_info "12-hour maintenance rebuild started for the reverse SSH tunnel."
        rebuild_tunnel "scheduled 12-hour rebuild" || {
            stop_update_server
            exit 1
        }
        HEALTH_CHECK_COUNT=0
    fi
done
