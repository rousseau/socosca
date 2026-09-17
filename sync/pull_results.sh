#!/bin/bash
# =============================================================================
# sync/pull_results.sh
# Rapatrie les résultats depuis une machine distante.
# Les données brutes (Data/) ne sont PAS rapatriées.
#
# Usage :
#   bash sync/pull_results.sh dgx-arm            # tous les pipelines
#   bash sync/pull_results.sh dgx-arm mrtrix     # pipeline spécifique
#   bash sync/pull_results.sh dgx-arm siam
# =============================================================================

set -euo pipefail

SYNC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
PROJ_DIR="$(dirname "$SYNC_DIR")"
CONF="${SYNC_DIR}/machines.conf.local"
[ -f "$CONF" ] || CONF="${SYNC_DIR}/machines.conf"

TARGET_ID="${1:?Usage: pull_results.sh <machine_id> [pipeline]}"
PIPELINE="${2:-}"   # optionnel : restreindre à un pipeline (mrtrix / siam / freesurfer / plots)

[ -f "$CONF" ] || { echo "[ERR] ${CONF} introuvable" >&2; exit 1; }

line=$(grep -E "^[[:space:]]*${TARGET_ID}[[:space:]]" "$CONF" || true)
if [ -z "$line" ]; then
    echo "[ERR] Machine '${TARGET_ID}' introuvable dans ${CONF}" >&2
    exit 1
fi

_HOST=$(echo "$line" | awk '{print $2}')
_DIR=$(echo "$line"  | awk '{print $3}')

LOCAL_RESULTS="${PROJ_DIR}/derivatives"
mkdir -p "$LOCAL_RESULTS"

echo ""
echo ">>> Pull depuis ${TARGET_ID} (${_HOST}:${_DIR}/derivatives/)"

if [ -n "$PIPELINE" ]; then
    # Rapatrier un seul pipeline
    mkdir -p "${LOCAL_RESULTS}/${PIPELINE}"
    rsync -avz --progress \
        "${_HOST}:${_DIR}/derivatives/${PIPELINE}/" \
        "${LOCAL_RESULTS}/${PIPELINE}/"
    echo "    [OK] derivatives/${PIPELINE}/"
else
    # Tout rapatrier sauf les fichiers .mif volumineux (déjà convertis en NIfTI)
    rsync -avz --progress \
        --exclude '*.mif' \
        --exclude 'tmp/' \
        "${_HOST}:${_DIR}/derivatives/" \
        "${LOCAL_RESULTS}/"
    echo "    [OK] derivatives/ (*.mif exclus)"
fi

echo ""
echo "Pull terminé depuis ${TARGET_ID}"
