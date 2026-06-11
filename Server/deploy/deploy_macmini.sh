#!/usr/bin/env zsh
set -euo pipefail

HOST="${1:-siriusl@192.168.3.79}"
PROJECT_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SERVER_ROOT="${PROJECT_ROOT}/Server"
SCRIPTS_ROOT="${PROJECT_ROOT}/Scripts"

REMOTE_AI="/Users/siriusl/AI"
REMOTE_SERVER="${REMOTE_AI}/VoiceScribeServer"
REMOTE_SCRIPTS="${REMOTE_AI}/VoiceScribeScripts"
LABEL="com.voicescribe.server"

echo "==> Creating remote directories on ${HOST}"
ssh "${HOST}" "mkdir -p '${REMOTE_SERVER}' '${REMOTE_SCRIPTS}' '\$HOME/.cache/VoiceScribeServer/logs'"

echo "==> Rsyncing Server code to remote"
rsync -az --delete \
  --exclude '.venv/' \
  --exclude '.pytest_cache/' \
  --exclude '__pycache__/' \
  --exclude '.env' \
  --exclude 'uploads/' \
  --exclude 'tasks/' \
  --exclude 'tasks.sqlite3*' \
  "${SERVER_ROOT}/" "${HOST}:${REMOTE_SERVER}/"

echo "==> Rsyncing Scripts to remote"
rsync -az --delete \
  --exclude '.git/' \
  --exclude '.venv/' \
  --exclude '__pycache__/' \
  --exclude '.DS_Store' \
  "${SCRIPTS_ROOT}/" "${HOST}:${REMOTE_SCRIPTS}/"

echo "==> Configuring environment and LaunchAgent on remote"
ssh "${HOST}" /bin/zsh <<REMOTE
set -euo pipefail

ROOT="${REMOTE_SERVER}"
ENV_FILE="\${ROOT}/.env"

chmod +x "\${ROOT}/run_server.sh"

if [[ ! -f "\${ENV_FILE}" ]]; then
  # Generate secure random token
  TOKEN="\$(/usr/bin/openssl rand -hex 32)"
  umask 077
  cat > "\${ENV_FILE}" <<EOF
VOICESCRIBE_TOKEN=\${TOKEN}
VOICESCRIBE_DATA_ROOT=\${HOME}/.cache/VoiceScribeServer
VOICESCRIBE_SCRIPTS_DIR=${REMOTE_SCRIPTS}
EOF
fi

chmod 600 "\${ENV_FILE}"

PLIST="\${HOME}/Library/LaunchAgents/com.voicescribe.server.plist"
mkdir -p "\${HOME}/Library/LaunchAgents"
sed -e "s|@HOME@|\${HOME}|g" -e "s|@SERVER_ROOT@|\${ROOT}|g" "\${ROOT}/deploy/com.voicescribe.server.plist" > "\${PLIST}"

# Bootstrap LaunchAgent
launchctl bootout "gui/\$(id -u)/com.voicescribe.server" 2>/dev/null || true
for _ in {1..20}; do
  if ! launchctl print "gui/\$(id -u)/com.voicescribe.server" >/dev/null 2>&1; then
    break
  fi
  sleep 0.25
done

launchctl bootstrap "gui/\$(id -u)" "\${PLIST}"
launchctl kickstart -k "gui/\$(id -u)/com.voicescribe.server"
REMOTE

echo "==> Successfully deployed ${LABEL} to ${HOST}"
