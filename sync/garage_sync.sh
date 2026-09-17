#!/bin/bash
# =============================================================================
# sync/garage_sync.sh
# Synchronise les données (sourcedata) et les résultats (derivatives) avec
# Garage (S3, hébergé sur l'une des machines du groupe) via rclone. Remplace
# le rsync SSH direct machine→machine pour les données : chaque machine
# pousse/tire depuis Garage, qui fait office de copie de référence centralisée.
#
# Utilise "rclone copy" (jamais "sync") : aucun fichier n'est supprimé côté
# destination, dans un sens comme dans l'autre.
#
# Usage :
#   bash sync/garage_sync.sh push-data    [--dry-run]
#   bash sync/garage_sync.sh pull-data    [--dry-run]
#   bash sync/garage_sync.sh push-results [pipeline] [--dry-run] [--remove-after-push]
#   bash sync/garage_sync.sh pull-results [pipeline] [--dry-run]
#
#   pipeline : mrtrix / siam / freesurfer / tractseg / scilpy / plots
#              (optionnel — omis = tous les pipelines)
#
#   --remove-after-push (push-results uniquement) : supprime les fichiers locaux
#   une fois transférés avec succès (rclone move), pour ne pas garder les
#   résultats volumineux sur la machine de traitement. Les *.mif ne sont jamais
#   transférés donc jamais supprimés (voir --exclude ci-dessous).
# =============================================================================

set -euo pipefail

SYNC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
PROJ_DIR="$(dirname "$SYNC_DIR")"

# shellcheck disable=SC1091
source "${PROJ_DIR}/config/garage.sh"

CYAN="\033[1;36m"
GREEN="\033[1;32m"
YELLOW="\033[1;33m"
RED="\033[1;31m"
RESET="\033[0m"

log()  { echo -e "\n${CYAN}[$(date '+%H:%M:%S')] $*${RESET}"; }
info() { echo -e "  ${GREEN}→${RESET} $*"; }
warn() { echo -e "  ${YELLOW}[WARN]${RESET} $*" >&2; }
die()  { echo -e "  ${RED}[ERR]${RESET}  $*" >&2; exit 1; }

usage() {
    cat <<EOF
Usage: $(basename "$0") <commande> [pipeline] [--dry-run] [--remove-after-push]

Commandes :
  push-data              ~/Data/Socosca/         -> garage:${GARAGE_BUCKET}/${GARAGE_PREFIX}/sourcedata/
  pull-data              garage:.../sourcedata/  -> ~/Data/Socosca/
  push-results [pipeline]  derivatives/[pipeline]/ -> garage:.../derivatives/[pipeline]/
  pull-results [pipeline]  garage:.../derivatives/[pipeline]/ -> derivatives/[pipeline]/

  --dry-run             affiche les transferts sans rien écrire (option rclone)
  --remove-after-push   (push-results) supprime les fichiers locaux transférés avec succès
EOF
    exit 0
}

command -v rclone >/dev/null 2>&1 || die "rclone introuvable — installer rclone et configurer le remote '${GARAGE_REMOTE}'"

CMD="${1:-}"
[ -n "$CMD" ] || usage
shift || true

PIPELINE=""
DRY_RUN=false
REMOVE_AFTER_PUSH=false
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=true ;;
        --remove-after-push) REMOVE_AFTER_PUSH=true ;;
        --help|-h) usage ;;
        *) PIPELINE="$arg" ;;
    esac
done

[ "$REMOVE_AFTER_PUSH" = true ] && [ "$CMD" != "push-results" ] && \
    die "--remove-after-push n'est valable qu'avec push-results"

DATA_DIR="${HOME}/Data/Socosca"
RESULTS_DIR="${PROJ_DIR}/derivatives"
REMOTE_SOURCEDATA="${GARAGE_REMOTE}:${GARAGE_BUCKET}/${GARAGE_PREFIX}/sourcedata"
REMOTE_DERIVATIVES="${GARAGE_REMOTE}:${GARAGE_BUCKET}/${GARAGE_PREFIX}/derivatives"

RCLONE_OPTS=(--exclude ".DS_Store" --exclude "__pycache__/**" --exclude "*.pyc" --progress)
[ "$DRY_RUN" = true ] && RCLONE_OPTS+=(--dry-run)

do_copy() {
    local label="$1" src="$2" dst="$3"; shift 3
    log "$label"
    info "${src} -> ${dst}"
    rclone copy "$src" "$dst" "${RCLONE_OPTS[@]}" "$@"
}

# rclone move ne supprime un fichier source qu'après confirmation du transfert
do_move() {
    local label="$1" src="$2" dst="$3"; shift 3
    log "${label} (suppression locale après succès)"
    info "${src} -> ${dst}"
    rclone move "$src" "$dst" "${RCLONE_OPTS[@]}" --delete-empty-src-dirs "$@"
}

case "$CMD" in
    push-data)
        [ -d "$DATA_DIR" ] || die "Répertoire introuvable : ${DATA_DIR}"
        do_copy "Push sourcedata -> Garage" "$DATA_DIR" "$REMOTE_SOURCEDATA"
        ;;
    pull-data)
        mkdir -p "$DATA_DIR"
        do_copy "Pull sourcedata <- Garage" "$REMOTE_SOURCEDATA" "$DATA_DIR"
        ;;
    push-results)
        results_local_dir="${RESULTS_DIR}${PIPELINE:+/${PIPELINE}}"
        results_remote_dir="${REMOTE_DERIVATIVES}${PIPELINE:+/${PIPELINE}}"
        [ -d "$results_local_dir" ] || die "Répertoire introuvable : ${results_local_dir}"
        if [ "$REMOVE_AFTER_PUSH" = true ]; then
            do_move "Push derivatives${PIPELINE:+ (${PIPELINE})} -> Garage" "$results_local_dir" "$results_remote_dir" --exclude "*.mif"
        else
            do_copy "Push derivatives${PIPELINE:+ (${PIPELINE})} -> Garage" "$results_local_dir" "$results_remote_dir" --exclude "*.mif"
        fi
        ;;
    pull-results)
        results_local_dir="${RESULTS_DIR}${PIPELINE:+/${PIPELINE}}"
        results_remote_dir="${REMOTE_DERIVATIVES}${PIPELINE:+/${PIPELINE}}"
        mkdir -p "$results_local_dir"
        do_copy "Pull derivatives${PIPELINE:+ (${PIPELINE})} <- Garage" "$results_remote_dir" "$results_local_dir" --exclude "*.mif"
        ;;
    *)
        die "Commande inconnue : ${CMD} (voir --help)"
        ;;
esac

log "Terminé."
