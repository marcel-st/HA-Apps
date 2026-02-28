#!/usr/bin/with-contenv bashio

SSH_HOST=$(bashio::config 'ssh_host')
SSH_PORT=$(bashio::config 'ssh_port')
SSH_USER=$(bashio::config 'ssh_user')
REMOTE_PORT=$(bashio::config 'remote_port')

mkdir -p /root/.ssh
chmod 700 /root/.ssh

bashio::log.info "Sleutel ophalen en opmaak herstellen..."

# 1. Haal de ruwe tekst op uit de config
RAW_KEY=$(jq -r '.private_key' /data/options.json)

# 2. Verwijder de BEGIN/END regels en alle spaties/enters om de pure base64 over te houden
# We gebruiken 'tr -d' om ALLES wat op een spatie of newline lijkt te slopen
CLEAN_BASE64=$(echo "$RAW_KEY" | sed 's/-----BEGIN [A-Z ]*-----//g' | sed 's/-----END [A-Z ]*-----//g' | tr -d '[:space:]')

# 3. Bouw de sleutel opnieuw op met de verplichte headers en regeleinden (fold -w 64)
echo "-----BEGIN OPENSSH PRIVATE KEY-----" > /root/.ssh/id_rsa
echo "$CLEAN_BASE64" | fold -w 64 >> /root/.ssh/id_rsa
echo "-----END OPENSSH PRIVATE KEY-----" >> /root/.ssh/id_rsa

# Zet de juiste permissies
chmod 600 /root/.ssh/id_rsa

# Controleer of de sleutel nu wel leesbaar is
if ! ssh-keygen -l -f /root/.ssh/id_rsa > /dev/null 2>&1; then
    bashio::log.error "De private key is nog steeds ongeldig na reparatie poging."
    exit 1
fi

bashio::log.info "Sleutel succesvol geladen. SSH-host scannen..."

# Voeg host toe aan known_hosts
ssh-keyscan -p $SSH_PORT $SSH_HOST >> /root/.ssh/known_hosts 2>/dev/null

bashio::log.info "Starten van reverse tunnel naar $SSH_HOST op poort $REMOTE_PORT..."

# Start autossh
export AUTOSSH_GATETIME=0
autossh -M 0 -o "ServerAliveInterval 30" -o "ServerAliveCountMax 3" -o "StrictHostKeyChecking=no" \
    -N -R $REMOTE_PORT:homeassistant:8123 $SSH_USER@$SSH_HOST -p $SSH_PORT -i /root/.ssh/id_rsa
