#!/bin/bash
# =============================================================================
# 04_siam_segmentation.sh
# Segmentation des volumes T1w avec SIAM (Segment It All Model)
# https://github.com/romainVala/SIAM
#
# Données d'entrée :
#   ~/Data/Socosca/sub-XX/anat/T1.nii.gz
#
# Sorties (format BIDS derivatives) :
#   ~/Exp/socosca/derivatives/siam/sub-XX/anat/
#     sub-XX_space-T1w_desc-siam_dseg.nii.gz   (segmentation 17 labels)
#
# Étiquettes SIAM (17 labels) :
#    0  : Background
#    1  : WM anomalies
#    2  : Skull
#    3  : Vessels
#    4  : Dura mater
#    5  : Head (soft tissue)
#    6  : White Matter
#    7  : Grey Matter
#    8  : CSF
#    9  : Cerebellum
#   10  : Ventricles
#   11–15 : Deep nuclei (×5)
#   16  : Hippocampus
#   17  : Amygdala
#
# Usage :
#   bash scripts/04_siam_segmentation.sh [--sub sub-01] [--device mps|cpu|cuda]
#   bash scripts/04_siam_segmentation.sh               # tous les sujets
#   SKIP_EXISTING=false bash scripts/04_siam_segmentation.sh
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Config machine (chemins, outils, threads)
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../config/machine.sh"

# ---------------------------------------------------------------------------
# Valeurs par défaut
# ---------------------------------------------------------------------------
DATA_DIR="${HOME}/Data/Socosca"
EXP_DIR="${HOME}/Exp/socosca"
PIPELINE="siam"

SKIP_EXISTING="${SKIP_EXISTING:-true}"
SUBJECT_ARG=""
DEVICE="${SIAM_DEVICE}"

# ---------------------------------------------------------------------------
# Parsing des arguments
# ---------------------------------------------------------------------------
usage() {
    echo "Usage: $(basename "$0") [--sub <id>] [--device <cpu|cuda|mps>] [--force]"
    echo "  --sub      traiter un seul sujet (ex: sub-01)"
    echo "  --device   périphérique inference (défaut: ${DEVICE})"
    echo "  --force    relancer tous les calculs même si les résultats existent"
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --sub)    SUBJECT_ARG="$2"; shift 2 ;;
        --device) DEVICE="$2";      shift 2 ;;
        --force)  SKIP_EXISTING="false"; shift ;;
        --help|-h) usage ;;
        *)        echo "Argument inconnu : $1"; exit 1 ;;
    esac
done

# ---------------------------------------------------------------------------
# Vérification disponibilité SIAM sur cette machine
# ---------------------------------------------------------------------------
if [ "${SIAM_AVAILABLE}" = "false" ]; then
    echo "[WARN] SIAM non disponible sur ${MACHINE_ID} (SIAM_AVAILABLE=false)" >&2
    echo "       Lancer ce script sur une machine avec GPU (ex: dgx-arm)" >&2
    exit 0
fi

# ---------------------------------------------------------------------------
# Répertoires de sortie
# ---------------------------------------------------------------------------
RESULTS_ROOT="${EXP_DIR}/derivatives/${PIPELINE}"
mkdir -p "$RESULTS_ROOT"

# Vérifier que siam-pred est accessible
if ! command -v "${SIAM_CMD}" > /dev/null 2>&1 && [ ! -x "${SIAM_CMD}" ]; then
    echo "[ERR] siam-pred introuvable : ${SIAM_CMD}" >&2
    echo "      Vérifier SIAM_CMD dans config/${MACHINE_ID}.sh" >&2
    exit 1
fi
echo "  → siam-pred : ${SIAM_CMD}"

# ---------------------------------------------------------------------------
# Fonctions utilitaires
# ---------------------------------------------------------------------------
CYAN="\033[1;36m"
GREEN="\033[1;32m"
YELLOW="\033[1;33m"
RED="\033[1;31m"
RESET="\033[0m"

log()  { echo -e "\n${CYAN}[$(date '+%H:%M:%S')] $*${RESET}"; }
info() { echo -e "  ${GREEN}→${RESET} $*"; }
warn() { echo -e "  ${YELLOW}[WARN]${RESET} $*" >&2; }
die()  { echo -e "  ${RED}[ERR]${RESET}  $*" >&2; exit 1; }

skip_if_exists() {
    local file="$1" label="${2:-$(basename "$1")}"
    if [ "${SKIP_EXISTING}" = "true" ] && [ -f "$file" ]; then
        echo -e "  ${YELLOW}[SKIP]${RESET} ${label}"
        return 0
    fi
    return 1
}

# ---------------------------------------------------------------------------
# Sélection des sujets
# ---------------------------------------------------------------------------
if [ -n "$SUBJECT_ARG" ]; then
    SUBJECTS=("$SUBJECT_ARG")
else
    SUBJECTS=()
    while IFS= read -r _s; do SUBJECTS+=("$_s"); done < <(
        find "$DATA_DIR" -maxdepth 1 -type d -name "sub-*" | sort | xargs -I{} basename {})
fi

log "Pipeline ${PIPELINE} — ${#SUBJECTS[@]} sujet(s) | machine=${MACHINE_ID} | device=${DEVICE} | skip_existing=${SKIP_EXISTING}"

# ===========================================================================
# BOUCLE PAR SUJET
# ===========================================================================
for SUBJECT_ID in "${SUBJECTS[@]}"; do

    SUBJECT="${DATA_DIR}/${SUBJECT_ID}"
    [ -d "$SUBJECT" ] || { warn "Répertoire $SUBJECT introuvable — sujet ignoré"; continue; }

    T1="${SUBJECT}/anat/T1.nii.gz"
    [ -f "$T1" ] || { warn "${SUBJECT_ID} : T1.nii.gz introuvable"; continue; }

    OUT_ANAT="${RESULTS_ROOT}/${SUBJECT_ID}/anat"
    mkdir -p "$OUT_ANAT"

    # Nom de sortie BIDS
    SEG_OUT="${OUT_ANAT}/${SUBJECT_ID}_space-T1w_desc-siam_dseg.nii.gz"

    log "SUJET : ${SUBJECT_ID}"

    if skip_if_exists "$SEG_OUT" "segmentation SIAM déjà présente"; then
        continue
    fi

    # siam-pred écrit dans un sous-dossier basé sur l'OUTPUT_PREFIX.
    # siam-pred construit son chemin de sortie comme :
    #   $(dirname $T1)/siamV03_<label>/<fichier>.nii.gz
    # Il faut passer un label court (pas un chemin absolu) sous peine d'obtenir
    # un chemin absurde imbriqué dans le répertoire des données d'entrée.
    SIAM_LABEL="siamout_${SUBJECT_ID}"
    T1_DIR="$(dirname "$T1")"

    info "Lancement siam-pred (device=${DEVICE})…"
    "$SIAM_CMD" \
        -i     "$T1" \
        -o     "$SIAM_LABEL" \
        -device "$DEVICE"

    # siam-pred peut écrire via un background worker (resampling asynchrone).
    # SIAM peut concaténer le stem du T1 au label (ex: siamV03_siamout_sub-01T1/).
    # On cherche donc par glob : siamV03_${SIAM_LABEL}* sous T1_DIR.
    # Attendre jusqu'à 300 s qu'un .nii.gz apparaisse.
    SIAM_RAW=""
    for _wait in $(seq 0 5 300); do
        SIAM_RAW=$(find "${T1_DIR}" -maxdepth 2 -name "*.nii.gz" \
                   -path "*/siamV03_${SIAM_LABEL}*" 2>/dev/null | head -1)
        [ -n "$SIAM_RAW" ] && break
        [ "$_wait" -gt 0 ] && info "En attente de la sortie siam-pred (${_wait}s)…"
        sleep 5
    done

    if [ -z "$SIAM_RAW" ]; then
        warn "${SUBJECT_ID} : aucun fichier trouvé sous ${T1_DIR}/siamV03_${SIAM_LABEL}*"
        warn "Contenu de ${T1_DIR} :"
        find "${T1_DIR}" -maxdepth 2 -type f 2>/dev/null | sed 's/^/    /' >&2 || true
        continue
    fi

    # Déplacer vers la destination BIDS
    mv "$SIAM_RAW" "$SEG_OUT"

    # Nettoyer les sous-dossiers siamV03_* créés dans T1_DIR.
    # IMPORTANT : on ne supprime QUE les dossiers dont le nom commence par siamV03_
    # (jamais T1_DIR lui-même) pour éviter d'effacer les données d'entrée par erreur.
    while IFS= read -r -d '' _siam_dir; do
        # Garde-fou : ne jamais supprimer T1_DIR
        if [ "$_siam_dir" = "$T1_DIR" ] || [ "$_siam_dir" = "${T1_DIR}/" ]; then
            warn "Sécurité : refus de supprimer T1_DIR ${_siam_dir}"
            continue
        fi
        info "Nettoyage dossier temporaire SIAM : ${_siam_dir}"
        rm -rf "$_siam_dir"
    done < <(find "$T1_DIR" -maxdepth 1 -type d -name "siamV03_${SIAM_LABEL}*" -print0 2>/dev/null)

    info "Segmentation → $(basename "$SEG_OUT")"

    # Statistiques rapides (volumes par label)
    python3 - <<PYEOF
import nibabel as nib, numpy as np, os
img = nib.load("${SEG_OUT}")
data = np.asarray(img.dataobj, dtype=np.int16)
vox_vol = np.prod(img.header.get_zooms()[:3]) / 1000  # cm³
labels = np.unique(data[data > 0])
print(f"  Labels trouvés : {len(labels)}  |  voxel = {np.prod(img.header.get_zooms()[:3]):.3f} mm³")
for lbl in labels:
    vol = (data == lbl).sum() * vox_vol
    print(f"    label {lbl:2d} : {vol:8.2f} cm³")
PYEOF

    log ">>> ${SUBJECT_ID} terminé — ${SEG_OUT}"
done

log "Pipeline ${PIPELINE} terminé."
echo ""
echo "Résultats : ${RESULTS_ROOT}"
