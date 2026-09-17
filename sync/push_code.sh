#!/bin/bash
# =============================================================================
# sync/push_code.sh
# Synchronise scripts/ et config/ vers toutes les machines distantes.
# Les données brutes (Data/) et les résultats (derivatives/) ne sont PAS poussés.
#
# Usage :
#   bash sync/push_code.sh           # vers toutes les machines
#   bash sync/push_code.sh dgx-arm   # vers une machine spécifique
# =============================================================================

set -euo pipefail

SYNC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
PROJ_DIR="$(dirname "$SYNC_DIR")"
CONF="${SYNC_DIR}/machines.conf.local"
[ -f "$CONF" ] || CONF="${SYNC_DIR}/machines.conf"
TARGET="${1:-}"     # optionnel : restreindre à une machine

[ -f "$CONF" ] || { echo "[ERR] ${CONF} introuvable" >&2; exit 1; }

_pushed=0
while IFS= read -r line; do
    # Ignorer commentaires et lignes vides
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    [[ -z "${line// }" ]] && continue

    _ID=$(echo "$line"   | awk '{print $1}')
    _HOST=$(echo "$line" | awk '{print $2}')
    _DIR=$(echo "$line"  | awk '{print $3}')

    [ -n "$TARGET" ] && [ "$_ID" != "$TARGET" ] && continue

    echo ""
    echo ">>> Push vers ${_ID} (${_HOST}:${_DIR})"

    # Créer le dossier distant si nécessaire
    ssh "$_HOST" "mkdir -p '${_DIR}/scripts' '${_DIR}/config' '${_DIR}/sync'"

    rsync -avz --delete \
        --exclude 'derivatives/' \
        --exclude '__pycache__/' \
        --exclude '*.pyc' \
        --exclude '.git/' \
        --exclude 'dwifslpreproc-tmp-*/' \
        "${PROJ_DIR}/scripts/"  "${_HOST}:${_DIR}/scripts/"
    rsync -avz --delete \
        "${PROJ_DIR}/config/"   "${_HOST}:${_DIR}/config/"
    rsync -avz --delete \
        "${PROJ_DIR}/sync/"     "${_HOST}:${_DIR}/sync/"
    [ -f "${PROJ_DIR}/README.md" ] && \
        rsync -avz "${PROJ_DIR}/README.md" "${_HOST}:${_DIR}/"

    # Rendre les scripts exécutables sur la machine distante
    ssh "$_HOST" "chmod +x '${_DIR}/scripts/'*.sh '${_DIR}/sync/'*.sh 2>/dev/null || true"

    echo "    [OK] ${_ID}"
    (( _pushed++ )) || true
done < "$CONF"

if [ "$_pushed" -eq 0 ]; then
    echo "[WARN] Aucune machine synchronisée${TARGET:+ (cible : ${TARGET} inconnue)}"
else
    echo ""
    echo "Push terminé — ${_pushed} machine(s) synchronisée(s)"
fi
