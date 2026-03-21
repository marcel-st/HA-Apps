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

    log_info "SSH private key ophalen en herstellen."

    raw_key=$(jq -r '.private_key' /data/options.json)
    clean_base64=$(printf '%s' "${raw_key}" | sed 's/-----BEGIN [A-Z ]*-----//g' | sed 's/-----END [A-Z ]*-----//g' | tr -d '[:space:]')

    {
        echo "-----BEGIN OPENSSH PRIVATE KEY-----"
        printf '%s\n' "${clean_base64}" | fold -w 64
        echo "-----END OPENSSH PRIVATE KEY-----"
    } > "${SSH_KEY_PATH}"

    chmod 600 "${SSH_KEY_PATH}"

    if ! ssh-keygen -l -f "${SSH_KEY_PATH}" >/dev/null 2>&1; then
        log_error "De private key blijft ongeldig na reparatiepoging."
        exit 1
    fi

    touch "${KNOWN_HOSTS_PATH}"
    chmod 600 "${KNOWN_HOSTS_PATH}"

    log_info "SSH private key succesvol geladen."
}

refresh_known_hosts() {
    log_info "SSH host key ophalen voor ${SSH_HOST}:${SSH_PORT}."

    if ! ssh-keyscan -H -p "${SSH_PORT}" "${SSH_HOST}" >> "${KNOWN_HOSTS_PATH}" 2>/dev/null; then
        log_warn "Kon de host key niet vooraf ophalen. Verbinding gaat verder met StrictHostKeyChecking=no."
    fi
}

stop_tunnel() {
    if [ -S "${CONTROL_SOCKET}" ]; then
        run_with_timeout 5 ssh -S "${CONTROL_SOCKET}" -O exit -p "${SSH_PORT}" "${SSH_TARGET}" >/dev/null 2>&1 || true
    fi

    if is_tunnel_running; then
        log_info "Stoppen van bestaande reverse tunnel met PID ${AUTOSSH_PID}."
        kill "${AUTOSSH_PID}" 2>/dev/null || true

        for ((i = 0; i < 10; i++)); do
            if ! is_tunnel_running; then
                break
            fi
            sleep 1
        done

        if is_tunnel_running; then
            log_warn "Tunnelproces reageerde niet op SIGTERM, forceer stop."
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

    log_info "Start reverse SSH tunnel naar ${SSH_HOST}:${SSH_PORT} met remote poort ${REMOTE_PORT}."

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
        log_error "Tunnelproces stopte direct na het starten."
        AUTOSSH_PID=""
        return 1
    fi

    log_info "Reverse SSH tunnel gestart met PID ${AUTOSSH_PID}."
    return 0
}

check_control_connection() {
    if [ ! -S "${CONTROL_SOCKET}" ]; then
        HEALTH_FAILURE_REASON="control socket ontbreekt"
        return 1
    fi

    if ! ssh -S "${CONTROL_SOCKET}" -O check -p "${SSH_PORT}" "${SSH_TARGET}" >/dev/null 2>&1; then
        HEALTH_FAILURE_REASON="SSH control connection is niet actief"
        return 1
    fi

    if ! run_with_timeout 20 ssh -S "${CONTROL_SOCKET}" -o ControlMaster=no -o ControlPath="${CONTROL_SOCKET}" -o BatchMode=yes -p "${SSH_PORT}" "${SSH_TARGET}" exit >/dev/null 2>&1; then
        HEALTH_FAILURE_REASON="bestaande SSH verbinding reageert niet meer"
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
        log_warn "Remote host ondersteunt geen ss, netstat, lsof of nc. Listener-check wordt uitgeschakeld; SSH health probe blijft actief."
        REMOTE_LISTENER_CHECK_ENABLED=0
        return 0
    fi

    HEALTH_FAILURE_REASON="remote poort ${REMOTE_PORT} luistert niet meer op ${SSH_HOST}"
    return 1
}

probe_tunnel_health() {
    HEALTH_FAILURE_REASON=""

    if ! is_tunnel_running; then
        HEALTH_FAILURE_REASON="autossh proces draait niet"
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

        log_warn "Tunnel nog niet gezond na start (poging ${attempt}/10): ${HEALTH_FAILURE_REASON}."
        sleep 3
    done

    return 1
}

rebuild_tunnel() {
    local reason="$1"

    log_warn "Reverse SSH tunnel wordt opnieuw opgebouwd: ${reason}."
    stop_tunnel

    if ! start_tunnel; then
        log_error "Opnieuw opbouwen van de reverse tunnel is mislukt tijdens het starten."
        return 1
    fi

    if ! wait_for_healthy_tunnel; then
        log_error "Opnieuw opgebouwde tunnel is niet gezond geworden: ${HEALTH_FAILURE_REASON}."
        return 1
    fi

    log_info "Reverse SSH tunnel opnieuw opgebouwd en gezond."
    return 0
}

shutdown() {
    log_info "Stop-signaal ontvangen, reverse tunnel wordt afgesloten."
    stop_tunnel
    exit 0
}

trap shutdown SIGINT SIGTERM SIGHUP

prepare_ssh_key
refresh_known_hosts

if ! start_tunnel; then
    exit 1
fi

if ! wait_for_healthy_tunnel; then
    log_error "Initiële reverse tunnel is niet gezond geworden: ${HEALTH_FAILURE_REASON}."
    exit 1
fi

log_info "Health checks actief: elke ${HEALTH_CHECK_INTERVAL}s. Geforceerde rebuild elke 12 uur."

while true; do
    sleep "${HEALTH_CHECK_INTERVAL}"

    if ! probe_tunnel_health; then
        log_warn "Health check mislukt: ${HEALTH_FAILURE_REASON}."
        rebuild_tunnel "health check mislukt" || exit 1
        HEALTH_CHECK_COUNT=0
        continue
    fi

    HEALTH_CHECK_COUNT=$((HEALTH_CHECK_COUNT + 1))

    if [ $((HEALTH_CHECK_COUNT % HEALTH_LOG_INTERVAL)) -eq 0 ]; then
        log_info "Health check succesvol: reverse SSH tunnel is nog actief."
    fi

    if [ $(( $(date +%s) - LAST_REBUILD_TS )) -ge "${REBUILD_INTERVAL}" ]; then
        log_info "12-uurs onderhoudsrebuild gestart voor de reverse SSH tunnel."
        rebuild_tunnel "geplande 12-uurs rebuild" || exit 1
        HEALTH_CHECK_COUNT=0
    fi
done
