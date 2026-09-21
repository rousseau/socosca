#!/bin/bash
# =============================================================================
# 05_freesurfer_segmentation.sh
# Segmentation corticale et sous-corticale avec FreeSurfer recon-all
# Résultats exportés en NIfTI au format BIDS derivatives
#
# Flux Garage (S3, via rclone) — identique au principe de 02_mrtrix_pipeline.sh
# (voir scripts/lib/garage_data.sh, mécanisme commun à tous les pipelines) :
#   1. Pull  garage:.../sourcedata/sub-XX/anat -> <WORK_DIR>/sourcedata/sub-XX/anat
#      (seul anat/ est nécessaire pour FreeSurfer, pas dwi/ ni fmap/)
#   2. Calcul local (recon-all natif + export BIDS) dans <WORK_DIR>/derivatives/freesurfer
#   3. Push <WORK_DIR>/derivatives/freesurfer/sub-XX -> garage:.../derivatives/freesurfer/sub-XX
#      (exports BIDS uniquement — le dossier natif recon-all "subjects/" n'est
#      jamais poussé : volumineux, redondant avec les NIfTI/GIFTI exportés)
#   Voir --no-pull / --no-push / --work-dir / --clean-sourcedata ci-dessous.
#
# Données d'entrée par sujet (nommage BIDS) :
#   <WORK_DIR>/sourcedata/sub-XX/anat/sub-XX_T1w.nii[.gz]
#
# Sorties (format BIDS derivatives) :
#   <WORK_DIR>/derivatives/freesurfer/sub-XX/anat/
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
#   <WORK_DIR>/derivatives/freesurfer/subjects/sub-XX/   (dossier natif recon-all,
#     local uniquement — nécessaire pour reprendre un run partiel)
#
# Usage :
#   bash scripts/05_freesurfer_segmentation.sh [--sub sub-01] [--nthreads 8]
#   bash scripts/05_freesurfer_segmentation.sh               # tous les sujets (liste depuis Garage)
#   bash scripts/05_freesurfer_segmentation.sh --no-push     # calcul local, sans repousser vers Garage
#   bash scripts/05_freesurfer_segmentation.sh --no-pull --sub sub-01  # rejouer sur une copie locale déjà présente
#   SKIP_EXISTING=false bash scripts/05_freesurfer_segmentation.sh
#   RECON_ONLY=true bash scripts/05_freesurfer_segmentation.sh  # recon-all sans export
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Config machine (chemins, outils, threads) + mécanisme commun d'accès Garage
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../config/machine.sh"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/garage_data.sh"

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
WORK_DIR="${SOCOSCA_WORK_DIR:-${HOME}/socosca-work}"
DATA_DIR="${WORK_DIR}/sourcedata"
PIPELINE="freesurfer"

SKIP_EXISTING="${SKIP_EXISTING:-true}"
RECON_ONLY="${RECON_ONLY:-false}"
NTHR="${NTHR_DEFAULT}"
SUBJECT_ARG=""
DO_PULL=true
DO_PUSH=true
CLEAN_SOURCEDATA=false

# ---------------------------------------------------------------------------
# Parsing des arguments
# ---------------------------------------------------------------------------
usage() {
    cat <<EOF
Usage: $(basename "$0") [--sub <id>] [--nthreads <n>] [--recon-only] [--force] [options]

  --sub               traiter un seul sujet (ex: sub-01)
  --nthreads          nombre de threads (défaut: ${NTHR})
  --recon-only        ne lancer que recon-all, pas l'export NIfTI
  --force             relancer tous les calculs même si les résultats existent
  --work-dir <dir>    répertoire de travail local (défaut: ${WORK_DIR})
  --no-pull           ne pas rapatrier sourcedata depuis Garage (copie locale existante requise)
  --no-push           ne pas repousser les dérivés vers Garage (calcul local uniquement)
  --clean-sourcedata  supprimer la copie locale de sourcedata une fois le sujet traité
EOF
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --sub)               SUBJECT_ARG="$2"; shift 2 ;;
        --nthreads)          NTHR="$2";        shift 2 ;;
        --recon-only)        RECON_ONLY="true"; shift ;;
        --force)             SKIP_EXISTING="false"; shift ;;
        --work-dir)          WORK_DIR="$2"; DATA_DIR="${WORK_DIR}/sourcedata"; shift 2 ;;
        --no-pull)           DO_PULL=false; shift ;;
        --no-push)           DO_PUSH=false; shift ;;
        --clean-sourcedata)  CLEAN_SOURCEDATA=true; shift ;;
        --help|-h)           usage ;;
        *)            echo "Argument inconnu : $1"; exit 1 ;;
    esac
done

require_rclone_if_needed

# ---------------------------------------------------------------------------
# Répertoires de sortie
# ---------------------------------------------------------------------------
# Subjects_dir FreeSurfer (dossier natif recon-all — local uniquement, jamais poussé)
FS_SUBJECTS_DIR="${WORK_DIR}/derivatives/${PIPELINE}/subjects"

# Dossier BIDS derivatives (poussé vers Garage)
RESULTS_ROOT="${WORK_DIR}/derivatives/${PIPELINE}"

mkdir -p "$DATA_DIR" "$FS_SUBJECTS_DIR" "$RESULTS_ROOT"
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
        # mris_convert écrit toujours sous <hémisphère>.<nom demandé> (préfixe
        # lh./rh. de "$morph"), quel que soit le chemin donné en sortie —
        # renommer vers le nom BIDS attendu.
        local hemi_prefix mis_named
        hemi_prefix="${morph##*/}"; hemi_prefix="${hemi_prefix%%.*}"
        mis_named="$(dirname "$dst")/${hemi_prefix}.$(basename "$dst")"
        [ -f "$mis_named" ] && mv "$mis_named" "$dst"
        info "$(basename "$morph") → $(basename "$dst")"
    fi
}

# ---------------------------------------------------------------------------
# Sélection des sujets (mécanisme commun — scripts/lib/garage_data.sh)
# ---------------------------------------------------------------------------
select_subjects

log "Pipeline ${PIPELINE} — ${#SUBJECTS[@]} sujet(s) | threads=${NTHR} | skip_existing=${SKIP_EXISTING} | work_dir=${WORK_DIR} | pull=${DO_PULL} | push=${DO_PUSH}"

# ===========================================================================
# BOUCLE PAR SUJET
# ===========================================================================
for SUBJECT_ID in "${SUBJECTS[@]}"; do

    SUBJECT="${DATA_DIR}/${SUBJECT_ID}"

    if [ "$DO_PULL" = true ]; then
        log "Pull sourcedata Garage -> local (${SUBJECT_ID}, anat/ uniquement)"
        # FreeSurfer n'a besoin que du T1w -> on ne rapatrie que anat/
        pull_subject_sourcedata "$SUBJECT_ID" anat
    fi

    [ -d "$SUBJECT" ] || { warn "Répertoire $SUBJECT introuvable — sujet ignoré (pull échoué ou sujet absent)"; continue; }

    T1=$(find_t1w "$SUBJECT" "$SUBJECT_ID")
    [ -n "$T1" ] || { warn "${SUBJECT_ID} : T1w introuvable (anat/${SUBJECT_ID}_T1w.nii[.gz])"; continue; }

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

    if [ "${RECON_ONLY}" = "true" ]; then
        if [ "$CLEAN_SOURCEDATA" = true ]; then
            clean_sourcedata "$SUBJECT_ID"
            info "Sourcedata locale supprimée : ${SUBJECT}"
        fi
        continue
    fi

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

    if [ "$DO_PUSH" = true ]; then
        log "Push derivatives -> Garage (${SUBJECT_ID})"
        # RESULTS_ROOT/${SUBJECT_ID} ne contient que les exports BIDS (anat/) —
        # le dossier natif recon-all vit dans FS_SUBJECTS_DIR, un chemin frère,
        # donc jamais inclus ici (pas d'exclude nécessaire).
        push_subject_results "$PIPELINE" "$SUBJECT_ID" "${RESULTS_ROOT}/${SUBJECT_ID}"
        info "Poussé vers Garage : derivatives/${PIPELINE}/${SUBJECT_ID}"
    fi

    if [ "$CLEAN_SOURCEDATA" = true ]; then
        clean_sourcedata "$SUBJECT_ID"
        info "Sourcedata locale supprimée : ${SUBJECT}"
    fi

done

log "Pipeline ${PIPELINE} terminé."
echo ""
echo "Dossier FreeSurfer natif : ${FS_SUBJECTS_DIR}"
echo "Exports BIDS NIfTI      : ${RESULTS_ROOT}"
