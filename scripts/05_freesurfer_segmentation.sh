#!/bin/bash
# =============================================================================
# 05_freesurfer_segmentation.sh
# Segmentation corticale et sous-corticale avec FreeSurfer recon-all
# Résultats exportés en NIfTI au format BIDS derivatives
#
# Données d'entrée :
#   ~/Data/Socosca/sub-XX/anat/T1.nii.gz
#
# Sorties (format BIDS derivatives) :
#   ~/Exp/socosca/results/freesurfer/sub-XX/anat/
#     sub-XX_space-T1w_desc-brain_T1w.nii.gz      (cerveau extrait)
#     sub-XX_space-T1w_desc-aseg_dseg.nii.gz       (segmentation sous-corticale aseg)
#     sub-XX_space-T1w_desc-aparc+aseg_dseg.nii.gz (segmentation corticale parcellisée)
#     sub-XX_space-T1w_desc-wmparc_dseg.nii.gz     (parcellisation WM)
#     sub-XX_hemi-L_desc-pial_surf.surf.gii         (surface piale gauche, GIFTI)
#     sub-XX_hemi-R_desc-pial_surf.surf.gii
#     sub-XX_hemi-L_desc-white_surf.surf.gii
#     sub-XX_hemi-R_desc-white_surf.surf.gii
#     sub-XX_hemi-L_desc-thickness_morph.shape.gii  (épaisseur corticale)
#     sub-XX_hemi-R_desc-thickness_morph.shape.gii
#
# Usage :
#   bash scripts/05_freesurfer_segmentation.sh [--sub sub-01] [--nthreads 8]
#   bash scripts/05_freesurfer_segmentation.sh               # tous les sujets
#   SKIP_EXISTING=false bash scripts/05_freesurfer_segmentation.sh
#   RECON_ONLY=true bash scripts/05_freesurfer_segmentation.sh  # recon-all sans export
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Config machine (chemins, outils, threads)
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../config/machine.sh"

# ---------------------------------------------------------------------------
# Configuration FreeSurfer
# ---------------------------------------------------------------------------
if [ ! -f "${FREESURFER_HOME}/FreeSurferEnv.sh" ]; then
    echo "[ERR] FreeSurfer introuvable dans ${FREESURFER_HOME}" >&2
    exit 1
fi

if [ -z "${FS_LICENSE:-}" ] || [ ! -f "${FS_LICENSE}" ]; then
    echo "[ERR] Licence FreeSurfer introuvable — définir FS_LICENSE dans config/${MACHINE_ID}.sh" >&2
    exit 1
fi

# Désactiver set -u/-e temporairement : FreeSurferEnv.sh référence des
# variables potentiellement non définies (FSL_DIR, MNI_DIR…)
set +eu
# shellcheck disable=SC1090
source "${FREESURFER_HOME}/FreeSurferEnv.sh" 2>/dev/null || true
set -eu
# Garantir que les binaires FreeSurfer sont dans le PATH
export PATH="${FREESURFER_HOME}/bin:${PATH}"

# ---------------------------------------------------------------------------
# Valeurs par défaut
# ---------------------------------------------------------------------------
DATA_DIR="${HOME}/Data/Socosca"
EXP_DIR="${HOME}/Exp/socosca"
PIPELINE="freesurfer"

SKIP_EXISTING="${SKIP_EXISTING:-true}"
RECON_ONLY="${RECON_ONLY:-false}"
NTHR="${NTHR_DEFAULT}"
SUBJECT_ARG=""

# Subjects_dir FreeSurfer (dossier natif recon-all)
FS_SUBJECTS_DIR="${EXP_DIR}/results/${PIPELINE}/subjects"

# Dossier BIDS derivatives
RESULTS_ROOT="${EXP_DIR}/results/${PIPELINE}"

# ---------------------------------------------------------------------------
# Parsing des arguments
# ---------------------------------------------------------------------------
usage() {
    echo "Usage: $(basename "$0") [--sub <id>] [--nthreads <n>] [--recon-only] [--force]"
    echo "  --sub         traiter un seul sujet (ex: sub-01)"
    echo "  --nthreads    nombre de threads (défaut: ${NTHR})"
    echo "  --recon-only  ne lancer que recon-all, pas l'export NIfTI"
    echo "  --force       relancer tous les calculs même si les résultats existent"
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --sub)        SUBJECT_ARG="$2"; shift 2 ;;
        --nthreads)   NTHR="$2";        shift 2 ;;
        --recon-only) RECON_ONLY="true"; shift ;;
        --force)      SKIP_EXISTING="false"; shift ;;
        --help|-h)    usage ;;
        *)            echo "Argument inconnu : $1"; exit 1 ;;
    esac
done

mkdir -p "$FS_SUBJECTS_DIR" "$RESULTS_ROOT"
export SUBJECTS_DIR="$FS_SUBJECTS_DIR"

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

# Conversion MGZ → NIfTI via mri_convert
mgz_to_nii() {
    local src="$1" dst="$2"
    if [ -f "$src" ] && { [ "${SKIP_EXISTING}" = "false" ] || [ ! -f "$dst" ]; }; then
        mri_convert "$src" "$dst" -rt nearest --no_scale 1
        info "$(basename "$src") → $(basename "$dst")"
    fi
}

# Conversion surface .surf → GIFTI via mris_convert
surf_to_gifti() {
    local src="$1" dst="$2"
    if [ -f "$src" ] && { [ "${SKIP_EXISTING}" = "false" ] || [ ! -f "$dst" ]; }; then
        mris_convert "$src" "$dst"
        info "$(basename "$src") → $(basename "$dst")"
    fi
}

# Conversion morphométrie .curv/.thickness → GIFTI shape
morph_to_gifti() {
    local surf="$1" morph="$2" dst="$3"
    if [ -f "$morph" ] && { [ "${SKIP_EXISTING}" = "false" ] || [ ! -f "$dst" ]; }; then
        mris_convert --annot "$morph" "$surf" "$dst" \
        || mris_convert -c "$morph" "$surf" "$dst"
        info "$(basename "$morph") → $(basename "$dst")"
    fi
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

log "Pipeline ${PIPELINE} — ${#SUBJECTS[@]} sujet(s) | threads=${NTHR} | skip_existing=${SKIP_EXISTING}"

# ===========================================================================
# BOUCLE PAR SUJET
# ===========================================================================
for SUBJECT_ID in "${SUBJECTS[@]}"; do

    SUBJECT="${DATA_DIR}/${SUBJECT_ID}"
    [ -d "$SUBJECT" ] || { warn "Répertoire $SUBJECT introuvable — sujet ignoré"; continue; }

    T1="${SUBJECT}/anat/T1.nii.gz"
    [ -f "$T1" ] || { warn "${SUBJECT_ID} : T1.nii.gz introuvable"; continue; }

    FS_DIR="${FS_SUBJECTS_DIR}/${SUBJECT_ID}"
    OUT_ANAT="${RESULTS_ROOT}/${SUBJECT_ID}/anat"
    mkdir -p "$OUT_ANAT"

    log "========================================================"
    log " SUJET : ${SUBJECT_ID}"
    log "========================================================"

    # ------------------------------------------------------------------
    # ÉTAPE 1 : recon-all
    # Le fichier de sortie cible est aparc+aseg.mgz (dernière étape)
    # ------------------------------------------------------------------
    RECON_DONE="${FS_DIR}/scripts/recon-all.done"

    if skip_if_exists "$RECON_DONE" "recon-all déjà terminé"; then
        info "FreeSurfer subjects dir : ${FS_DIR}"
    else
        log "[1/2] recon-all (peut prendre 6–10h par sujet)"

        # Si le dossier sujet existe déjà (run partiel), utiliser -autorecon-all
        # pour reprendre là où ça s'est arrêté
        if [ -d "$FS_DIR" ]; then
            info "Reprise d'un run partiel (recon-all -autorecon-all)"
            recon-all \
                -subjid  "$SUBJECT_ID" \
                -autorecon-all \
                -parallel -openmp "$NTHR" \
                -no-isrunning
        else
            recon-all \
                -subjid  "$SUBJECT_ID" \
                -i       "$T1" \
                -all \
                -parallel -openmp "$NTHR"
        fi
    fi

    [ "${RECON_ONLY}" = "true" ] && continue

    # ------------------------------------------------------------------
    # ÉTAPE 2 : Export NIfTI au format BIDS derivatives
    # ------------------------------------------------------------------
    log "[2/2] Export NIfTI (BIDS derivatives)"

    MRIDIR="${FS_DIR}/mri"
    SURFDIR="${FS_DIR}/surf"

    # Volumes MGZ → NIfTI -------------------------------------------------
    # Cerveau extrait (T1 dans l'espace FreeSurfer conformé 256³)
    mgz_to_nii "${MRIDIR}/brain.mgz" \
               "${OUT_ANAT}/${SUBJECT_ID}_space-T1w_desc-brain_T1w.nii.gz"

    # T1 original dans l'espace natif (non conformé)
    mgz_to_nii "${MRIDIR}/rawavg.mgz" \
               "${OUT_ANAT}/${SUBJECT_ID}_space-orig_T1w.nii.gz"

    # Segmentation sous-corticale (aseg)
    mgz_to_nii "${MRIDIR}/aseg.mgz" \
               "${OUT_ANAT}/${SUBJECT_ID}_space-T1w_desc-aseg_dseg.nii.gz"

    # Segmentation corticale parcellisée (aparc+aseg — Desikan-Killiany)
    mgz_to_nii "${MRIDIR}/aparc+aseg.mgz" \
               "${OUT_ANAT}/${SUBJECT_ID}_space-T1w_desc-aparc+aseg_dseg.nii.gz"

    # Parcellisation WM
    mgz_to_nii "${MRIDIR}/wmparc.mgz" \
               "${OUT_ANAT}/${SUBJECT_ID}_space-T1w_desc-wmparc_dseg.nii.gz"

    # Surfaces → GIFTI ----------------------------------------------------
    for HEMI in lh rh; do
        HEMI_BIDS="${HEMI/lh/L}"
        HEMI_BIDS="${HEMI_BIDS/rh/R}"

        surf_to_gifti "${SURFDIR}/${HEMI}.pial" \
            "${OUT_ANAT}/${SUBJECT_ID}_hemi-${HEMI_BIDS}_desc-pial_surf.surf.gii"

        surf_to_gifti "${SURFDIR}/${HEMI}.white" \
            "${OUT_ANAT}/${SUBJECT_ID}_hemi-${HEMI_BIDS}_desc-white_surf.surf.gii"

        surf_to_gifti "${SURFDIR}/${HEMI}.inflated" \
            "${OUT_ANAT}/${SUBJECT_ID}_hemi-${HEMI_BIDS}_desc-inflated_surf.surf.gii"

        # Épaisseur corticale
        morph_to_gifti \
            "${SURFDIR}/${HEMI}.white" \
            "${SURFDIR}/${HEMI}.thickness" \
            "${OUT_ANAT}/${SUBJECT_ID}_hemi-${HEMI_BIDS}_desc-thickness_morph.shape.gii"

        # Courbure moyenne
        morph_to_gifti \
            "${SURFDIR}/${HEMI}.white" \
            "${SURFDIR}/${HEMI}.curv" \
            "${OUT_ANAT}/${SUBJECT_ID}_hemi-${HEMI_BIDS}_desc-curv_morph.shape.gii"
    done

    # Tableau des volumes des structures (aseg.stats → TSV) ---------------
    STATS_TSV="${OUT_ANAT}/${SUBJECT_ID}_desc-aseg_stats.tsv"
    STATS_FILE="${FS_DIR}/stats/aseg.stats"
    if [ -f "$STATS_FILE" ] && { [ "${SKIP_EXISTING}" = "false" ] || [ ! -f "$STATS_TSV" ]; }; then
        python3 - <<PYEOF
import re, csv, sys

lines = open("${STATS_FILE}").readlines()
rows = []
for l in lines:
    if l.startswith('#') or not l.strip():
        continue
    parts = l.split()
    if len(parts) >= 5:
        rows.append({
            'Index':      parts[0],
            'SegId':      parts[1],
            'NVoxels':    parts[2],
            'Volume_mm3': parts[3],
            'StructName': parts[4],
            'normMean':   parts[5] if len(parts) > 5 else '',
            'normStdDev': parts[6] if len(parts) > 6 else '',
            'normMin':    parts[7] if len(parts) > 7 else '',
            'normMax':    parts[8] if len(parts) > 8 else '',
            'normRange':  parts[9] if len(parts) > 9 else '',
        })

if rows:
    with open("${STATS_TSV}", 'w', newline='') as f:
        writer = csv.DictWriter(f, fieldnames=rows[0].keys(), delimiter='\t')
        writer.writeheader()
        writer.writerows(rows)
    print(f"  → aseg_stats.tsv ({len(rows)} structures)")
PYEOF
    fi

    log ">>> ${SUBJECT_ID} terminé — ${OUT_ANAT}"

done

log "Pipeline ${PIPELINE} terminé."
echo ""
echo "Dossier FreeSurfer natif : ${FS_SUBJECTS_DIR}"
echo "Exports BIDS NIfTI      : ${RESULTS_ROOT}"
