#!/bin/bash
# =============================================================================
# 02_mrtrix_pipeline.sh
# Pipeline DWI complet — Projet Socosca
# Dépendances : MRtrix3, FSL (topup/eddy), ANTs (dwibiascorrect), rclone
#
# Données d'entrée par sujet (nommage BIDS, dans un répertoire de travail
# local dédié <WORK_DIR>/sourcedata/sub-XX/, rapatrié depuis Garage) :
#   anat/sub-XX_T1w.nii[.gz] + .json
#   dwi/sub-XX_acq-b1000_dwi.nii[.gz] + .bval/.bvec/.json
#   dwi/sub-XX_acq-b2000_dwi.nii[.gz] + .bval/.bvec/.json
#   fmap/sub-XX_dir-AP_epi.nii[.gz] + .json   (b0 AP — pour topup)
#   fmap/sub-XX_dir-PA_epi.nii[.gz] + .json   (b0 PA — pour topup)
#
# Flux Garage (S3, via rclone) :
#   1. Pull  garage:.../sourcedata/sub-XX -> <WORK_DIR>/sourcedata/sub-XX
#   2. Calculs locaux dans <WORK_DIR>/derivatives/mrtrix/sub-XX (+ plots/)
#   3. Push  <WORK_DIR>/derivatives/{mrtrix,plots}/sub-XX -> garage:.../derivatives/...
#   Voir --no-pull / --no-push / --work-dir / --clean-sourcedata ci-dessous.
#
# Étapes :
#   0. Conversion NIfTI → MIF + concaténation multi-shell
#   1. Débruitage MP-PCA (dwidenoise)
#   2. Correction anneaux de Gibbs (mrdegibbs)
#   3. Correction distorsion EPI + courant de Foucault + mouvement
#      (dwifslpreproc → topup + eddy)
#   4. Correction biais B1 (dwibiascorrect ants)
#  4b. Upsampling DWI → 1.25 mm isotrope (mrgrid)
#   5. Masque cerveau (dwi2mask — MRtrix3)
#   6. Modèle tensoriel DTI → FA, MD, AD, RD (shell b=1000)
#   7. Estimation de la fonction de réponse (dwi2response dhollander)
#   8. MSMT-CSD (dwi2fod msmt_csd)
#   9. Normalisation MT (mtnormalise)
#  10. Tractographie iFOD2 (tckgen) + filtrage SIFT2 (tcksift2)
#  QC. Figures de contrôle qualité (Python/matplotlib)
#
# Sorties (format BIDS derivatives, en local sous <WORK_DIR>/derivatives/) :
#   <WORK_DIR>/derivatives/mrtrix/sub-XX/dwi/
#   <WORK_DIR>/derivatives/mrtrix/sub-XX/anat/
#   <WORK_DIR>/derivatives/mrtrix/sub-XX/tractography/
#   <WORK_DIR>/derivatives/plots/sub-XX/
#
# Usage :
#   bash scripts/02_mrtrix_pipeline.sh [--sub sub-01] [--nthreads 8]
#   bash scripts/02_mrtrix_pipeline.sh                       # tous les sujets (liste depuis Garage)
#   bash scripts/02_mrtrix_pipeline.sh --sub sub-01          # un seul sujet
#   bash scripts/02_mrtrix_pipeline.sh --no-push             # calcul local, sans repousser vers Garage
#   bash scripts/02_mrtrix_pipeline.sh --no-pull --sub sub-01  # rejouer sur une copie locale déjà présente
#   SKIP_EXISTING=false bash scripts/02_mrtrix_pipeline.sh   # tout recalculer
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Config machine (chemins, outils, threads)
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../config/machine.sh"

# FSL : FSLDIR est défini par machine.sh, sourcer fsl.sh
# LD_LIBRARY_PATH pré-FSL sauvegardé pour restauration avant l'appel ANTs
# (étape 4) : les installs FSL conda embarquent leurs propres bibliothèques
# (libstdc++, etc.) et fsl.sh pointe LD_LIBRARY_PATH dessus, ce qui casse
# N4BiasFieldCorrection (ABI mismatch → "Invalid flag provided" incohérent).
_LD_LIBRARY_PATH_PRE_FSL="${LD_LIBRARY_PATH:-}"
if [ -f "${FSLDIR}/etc/fslconf/fsl.sh" ]; then
    set +eu
    # shellcheck disable=SC1090
    source "${FSLDIR}/etc/fslconf/fsl.sh"
    set -eu
else
    echo "[WARN] ${FSLDIR}/etc/fslconf/fsl.sh introuvable" >&2
fi

# ---------------------------------------------------------------------------
# Valeurs par défaut
# ---------------------------------------------------------------------------
WORK_DIR="${SOCOSCA_WORK_DIR:-${HOME}/socosca-work}"
DATA_DIR="${WORK_DIR}/sourcedata"
PIPELINE="mrtrix"

SKIP_EXISTING="${SKIP_EXISTING:-true}"
NTHR="${NTHR_DEFAULT}"
SUBJECT_ARG=""
UPSAMPLE_VOX="${UPSAMPLE_VOX:-1.25}"
DO_PULL=true
DO_PUSH=true
CLEAN_SOURCEDATA=false

# Tractographie
N_STREAMLINES=10000000
N_STREAMLINES_SIFT2=2000000

# ---------------------------------------------------------------------------
# Parsing des arguments
# ---------------------------------------------------------------------------
usage() {
    cat <<EOF
Usage: $(basename "$0") [--sub <id>] [--nthreads <n>] [--force] [options]

  --sub               traiter un seul sujet (ex: sub-01)
  --nthreads          nombre de threads (défaut: ${NTHR})
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
        --sub)              SUBJECT_ARG="$2"; shift 2 ;;
        --nthreads)         NTHR="$2";        shift 2 ;;
        --force)            SKIP_EXISTING="false"; shift ;;
        --upsample-vox)     UPSAMPLE_VOX="$2"; shift 2 ;;
        --work-dir)         WORK_DIR="$2"; DATA_DIR="${WORK_DIR}/sourcedata"; shift 2 ;;
        --no-pull)          DO_PULL=false; shift ;;
        --no-push)          DO_PUSH=false; shift ;;
        --clean-sourcedata) CLEAN_SOURCEDATA=true; shift ;;
        --help|-h)          usage ;;
        *)            echo "Argument inconnu : $1"; exit 1 ;;
    esac
done

if { [ "$DO_PULL" = true ] || [ "$DO_PUSH" = true ]; } && ! command -v rclone >/dev/null 2>&1; then
    echo "[ERR] rclone introuvable — installer rclone, ou utiliser --no-pull --no-push pour un test purement local" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Répertoires de sortie
# ---------------------------------------------------------------------------
RESULTS_ROOT="${WORK_DIR}/derivatives/${PIPELINE}"
PLOTS_ROOT="${WORK_DIR}/derivatives/plots"
mkdir -p "$DATA_DIR" "$RESULTS_ROOT" "$PLOTS_ROOT"

# ---------------------------------------------------------------------------
# Fonctions utilitaires
# ---------------------------------------------------------------------------
BOLD="\033[1m"
CYAN="\033[1;36m"
GREEN="\033[1;32m"
YELLOW="\033[1;33m"
RED="\033[1;31m"
RESET="\033[0m"

log()   { echo -e "\n${CYAN}[$(date '+%H:%M:%S')] $*${RESET}"; }
info()  { echo -e "  ${GREEN}→${RESET} $*"; }
warn()  { echo -e "  ${YELLOW}[WARN]${RESET} $*" >&2; }
die()   { echo -e "  ${RED}[ERR]${RESET}  $*" >&2; exit 1; }

# Retourne 0 (skip) si le fichier existe et SKIP_EXISTING=true
skip_if_exists() {
    local file="$1"
    local label="${2:-$(basename "$1")}"
    if [ "${SKIP_EXISTING}" = "true" ] && [ -f "$file" ]; then
        echo -e "  ${YELLOW}[SKIP]${RESET} ${label}"
        return 0
    fi
    return 1
}

# Sentinelles pour les étapes dont la sortie est supprimée après usage
# Garantit que --force ou SKIP_EXISTING=false relève les calculs
step_done() {
    local n="$1" label="${2:-étape $1}"
    if [ "${SKIP_EXISTING}" = "true" ] && [ -f "${TMP}/.step${n}.done" ]; then
        echo -e "  ${YELLOW}[SKIP]${RESET} ${label} (déjà terminée)"
        return 0
    fi
    return 1
}
mark_done() { touch "${TMP}/.step${1}.done"; }

# Extraire TotalReadoutTime depuis le JSON (défaut 0.1)
get_readout_time() {
    local json="$1"
    python3 -c "
import json, sys
try:
    d = json.load(open('${json}'))
    t = d.get('TotalReadoutTime', d.get('EstimatedTotalReadoutTime', 0.1))
    print(round(float(t), 6))
except Exception:
    print(0.1)
" 2>/dev/null
}

# ---------------------------------------------------------------------------
# Sélection des sujets
# ---------------------------------------------------------------------------
if [ -n "$SUBJECT_ARG" ]; then
    SUBJECTS=("$SUBJECT_ARG")
elif [ "$DO_PULL" = true ]; then
    SUBJECTS=()
    while IFS= read -r _s; do SUBJECTS+=("${_s%/}"); done < <(
        rclone lsf "${GARAGE_REMOTE}:${GARAGE_BUCKET}/${GARAGE_PREFIX}/sourcedata" --dirs-only 2>/dev/null | grep '^sub-' | sort)
    [ ${#SUBJECTS[@]} -eq 0 ] && die "Aucun sujet trouvé sur Garage (${GARAGE_BUCKET}/${GARAGE_PREFIX}/sourcedata) — vérifier rclone/le remote, ou utiliser --sub"
else
    SUBJECTS=()
    while IFS= read -r _s; do SUBJECTS+=("$_s"); done < <(
        find "$DATA_DIR" -maxdepth 1 -type d -name "sub-*" 2>/dev/null | sort | xargs -I{} basename {})
    [ ${#SUBJECTS[@]} -eq 0 ] && die "Aucun sujet trouvé localement dans ${DATA_DIR} (--no-pull requiert une copie locale déjà présente)"
fi

log "Pipeline ${PIPELINE} — ${#SUBJECTS[@]} sujet(s) | threads=${NTHR} | skip_existing=${SKIP_EXISTING} | work_dir=${WORK_DIR} | pull=${DO_PULL} | push=${DO_PUSH}"

# ===========================================================================
# BOUCLE PAR SUJET
# ===========================================================================
for SUBJECT_ID in "${SUBJECTS[@]}"; do

    SUBJECT="${DATA_DIR}/${SUBJECT_ID}"

    if [ "$DO_PULL" = true ]; then
        log "Pull sourcedata Garage -> local (${SUBJECT_ID})"
        mkdir -p "$SUBJECT"
        rclone copy "${GARAGE_REMOTE}:${GARAGE_BUCKET}/${GARAGE_PREFIX}/sourcedata/${SUBJECT_ID}" "$SUBJECT" \
            --exclude ".DS_Store" --quiet
    fi

    [ -d "$SUBJECT" ] || { warn "Répertoire $SUBJECT introuvable — sujet ignoré (pull échoué ou sujet absent)"; continue; }

    # ------------------------------------------------------------------
    # Répertoires BIDS derivatives
    # ------------------------------------------------------------------
    OUT_DWI="${RESULTS_ROOT}/${SUBJECT_ID}/dwi"
    OUT_ANAT="${RESULTS_ROOT}/${SUBJECT_ID}/anat"
    OUT_TRACT="${RESULTS_ROOT}/${SUBJECT_ID}/tractography"
    OUT_PLOTS="${PLOTS_ROOT}/${SUBJECT_ID}"
    TMP="${RESULTS_ROOT}/${SUBJECT_ID}/tmp"

    mkdir -p "$OUT_DWI" "$OUT_ANAT" "$OUT_TRACT" "$OUT_PLOTS" "$TMP"

    # Préfixe BIDS
    BIDS="${SUBJECT_ID}"

    # ------------------------------------------------------------------
    # Migration : créer les sentinelles pour les runs antérieurs
    # (exécutés avant l'introduction du mécanisme de sentinelles)
    # Principe : si une sortie persistante d'une étape ultérieure existe,
    # l'étape courante est forcément terminée.
    # Note : la fonction retourne toujours 0 pour ne pas déclencher set -e
    # ------------------------------------------------------------------
    _ms() {
        local n=$1; shift
        if [ -f "${TMP}/.step${n}.done" ]; then return 0; fi
        local _f
        for _f in "$@"; do
            if [ -f "$_f" ]; then
                touch "${TMP}/.step${n}.done"
                return 0
            fi
        done
        return 0   # étape pas encore faite — pas d'erreur
    }
    _ms 1 "${TMP}/${BIDS}_dwi_desc-denoised_dwi.mif" \
           "${TMP}/${BIDS}_dwi_desc-degibbs_dwi.mif" \
           "${TMP}/${BIDS}_dwi_desc-preproc_dwi.mif" \
           "${TMP}/${BIDS}_dwi_desc-biascorr_dwi.mif" \
           "${OUT_DWI}/${BIDS}_space-dwi_desc-brain_mask.nii.gz" \
           "${OUT_DWI}/${BIDS}_model-DTI_param-FA_dti.nii.gz" \
           "${OUT_DWI}/${BIDS}_desc-msmtNorm_model-CSD_wm.mif"
    _ms 2 "${TMP}/${BIDS}_dwi_desc-degibbs_dwi.mif" \
           "${TMP}/${BIDS}_dwi_desc-preproc_dwi.mif" \
           "${TMP}/${BIDS}_dwi_desc-biascorr_dwi.mif" \
           "${OUT_DWI}/${BIDS}_space-dwi_desc-brain_mask.nii.gz" \
           "${OUT_DWI}/${BIDS}_model-DTI_param-FA_dti.nii.gz" \
           "${OUT_DWI}/${BIDS}_desc-msmtNorm_model-CSD_wm.mif"
    _ms 3 "${TMP}/${BIDS}_dwi_desc-preproc_dwi.mif" \
           "${TMP}/${BIDS}_dwi_desc-biascorr_dwi.mif" \
           "${OUT_DWI}/${BIDS}_space-dwi_desc-brain_mask.nii.gz" \
           "${OUT_DWI}/${BIDS}_model-DTI_param-FA_dti.nii.gz" \
           "${OUT_DWI}/${BIDS}_desc-msmtNorm_model-CSD_wm.mif"
    _ms 4 "${TMP}/${BIDS}_dwi_desc-biascorr_dwi.mif" \
           "${TMP}/${BIDS}_dwi_desc-biascorr-upsampled_dwi.mif" \
           "${OUT_DWI}/${BIDS}_space-dwi_desc-brain_mask.nii.gz" \
           "${OUT_DWI}/${BIDS}_model-DTI_param-FA_dti.nii.gz" \
           "${OUT_DWI}/${BIDS}_desc-msmtNorm_model-CSD_wm.mif"
    _ms 4b "${OUT_DWI}/${BIDS}_space-dwi_desc-brain_mask.nii.gz" \
            "${OUT_DWI}/${BIDS}_model-DTI_param-FA_dti.nii.gz" \
            "${OUT_DWI}/${BIDS}_desc-msmtNorm_model-CSD_wm.mif"
    _ms 8 "${TMP}/${BIDS}_desc-msmt_model-CSD_wm.mif" \
           "${OUT_DWI}/${BIDS}_desc-msmtNorm_model-CSD_wm.mif"
    unset -f _ms

    log "========================================================"
    log " SUJET : ${SUBJECT_ID}"
    log "========================================================"

    # ------------------------------------------------------------------
    # Chemins des données brutes (nommage BIDS)
    # ------------------------------------------------------------------
    ANAT_DIR="${SUBJECT}/anat"
    DWI_DIR="${SUBJECT}/dwi"
    FMAP_DIR="${SUBJECT}/fmap"
    T1=$(ls "${ANAT_DIR}/${BIDS}_T1w.nii.gz" "${ANAT_DIR}/${BIDS}_T1w.nii" 2>/dev/null | head -1 || true)

    DWI_B1000=$(ls "${DWI_DIR}/${BIDS}_acq-b1000_dwi.nii.gz" "${DWI_DIR}/${BIDS}_acq-b1000_dwi.nii" 2>/dev/null | head -1 || true)
    DWI_B2000=$(ls "${DWI_DIR}/${BIDS}_acq-b2000_dwi.nii.gz" "${DWI_DIR}/${BIDS}_acq-b2000_dwi.nii" 2>/dev/null | head -1 || true)
    DWI_AP=$(ls    "${FMAP_DIR}/${BIDS}_dir-AP_epi.nii.gz"   "${FMAP_DIR}/${BIDS}_dir-AP_epi.nii"    2>/dev/null | head -1 || true)
    DWI_PA=$(ls    "${FMAP_DIR}/${BIDS}_dir-PA_epi.nii.gz"   "${FMAP_DIR}/${BIDS}_dir-PA_epi.nii"    2>/dev/null | head -1 || true)

    DWI_B1000_BVEC="${DWI_DIR}/${BIDS}_acq-b1000_dwi.bvec"
    DWI_B1000_BVAL="${DWI_DIR}/${BIDS}_acq-b1000_dwi.bval"
    DWI_B1000_JSON="${DWI_DIR}/${BIDS}_acq-b1000_dwi.json"
    DWI_B2000_BVEC="${DWI_DIR}/${BIDS}_acq-b2000_dwi.bvec"
    DWI_B2000_BVAL="${DWI_DIR}/${BIDS}_acq-b2000_dwi.bval"
    DWI_B2000_JSON="${DWI_DIR}/${BIDS}_acq-b2000_dwi.json"
    DWI_AP_JSON="${FMAP_DIR}/${BIDS}_dir-AP_epi.json"
    DWI_PA_JSON="${FMAP_DIR}/${BIDS}_dir-PA_epi.json"

    { [ -n "$T1" ] && [ -f "$T1" ]; }  || die "$SUBJECT_ID : T1w introuvable (anat/${BIDS}_T1w.nii[.gz])"
    [ -n "$DWI_B1000" ]                || die "$SUBJECT_ID : DWI acq-b1000 introuvable"
    [ -n "$DWI_B2000" ]                || die "$SUBJECT_ID : DWI acq-b2000 introuvable"
    [ -n "$DWI_AP" ]                   || die "$SUBJECT_ID : fmap dir-AP introuvable"
    [ -n "$DWI_PA" ]                   || die "$SUBJECT_ID : fmap dir-PA introuvable"

    READOUT_TIME=$(get_readout_time "$DWI_AP_JSON")
    info "TotalReadoutTime : ${READOUT_TIME}s"

    # ------------------------------------------------------------------
    # ÉTAPE 0 : Conversion NIfTI → MIF + concaténation multi-shell
    # ------------------------------------------------------------------
    log "[0/10] Conversion + concaténation multi-shell"

    MIF_CONCAT="${TMP}/${BIDS}_dwi_concat.mif"
    MIF_B0_PAIR="${TMP}/${BIDS}_b0_AP_PA.mif"

    if ! skip_if_exists "$MIF_CONCAT" "dwi_concat.mif" || [ ! -f "$MIF_B0_PAIR" ]; then

        MIF_B1000="${TMP}/${BIDS}_dwi_b1000.mif"
        MIF_B2000="${TMP}/${BIDS}_dwi_b2000.mif"

        mrconvert "$DWI_B1000" "$MIF_B1000" \
            -fslgrad "$DWI_B1000_BVEC" "$DWI_B1000_BVAL" \
            -json_import "$DWI_B1000_JSON" \
            -nthreads "$NTHR" -force -quiet

        mrconvert "$DWI_B2000" "$MIF_B2000" \
            -fslgrad "$DWI_B2000_BVEC" "$DWI_B2000_BVAL" \
            -json_import "$DWI_B2000_JSON" \
            -nthreads "$NTHR" -force -quiet

        mrcat "$MIF_B1000" "$MIF_B2000" "$MIF_CONCAT" \
            -axis 3 -nthreads "$NTHR" -force -quiet

        # Paire b0 AP + PA pour topup
        MIF_AP="${TMP}/${BIDS}_b0_AP.mif"
        MIF_PA="${TMP}/${BIDS}_b0_PA.mif"

        # Les fichiers AP/PA sont des acquisitions b0 pures (pas de table de
        # gradients) → mrconvert direct, pas de dwiextract -bzero
        mrconvert "$DWI_AP" "$MIF_AP" \
            -json_import "$DWI_AP_JSON" \
            -nthreads "$NTHR" -force -quiet
        mrconvert "$DWI_PA" "$MIF_PA" \
            -json_import "$DWI_PA_JSON" \
            -nthreads "$NTHR" -force -quiet

        # Concaténation directe AP + PA (déjà des b0)
        mrcat "$MIF_AP" "$MIF_PA" \
              "$MIF_B0_PAIR" -axis 3 -nthreads "$NTHR" -force -quiet

        rm -f "$MIF_B1000" "$MIF_B2000" "$MIF_AP" "$MIF_PA"

        NVOLS=$(mrinfo "$MIF_CONCAT" -size | awk '{print $4}')
        info "Concat : ${NVOLS} volumes (b1000+b2000)"
    fi

    # ------------------------------------------------------------------
    # ÉTAPE 1 : Débruitage MP-PCA (dwidenoise)
    # Note : doit être la PREMIÈRE opération avant toute interpolation
    # ------------------------------------------------------------------
    log "[1/10] Débruitage MP-PCA (dwidenoise)"

    DWI_DENOISED="${TMP}/${BIDS}_dwi_desc-denoised_dwi.mif"
    NOISE_MAP="${OUT_DWI}/${BIDS}_desc-noiseMap_dwi.nii.gz"

    # Sentinelle : DWI_DENOISED est supprimé après l'étape 2
    DENOISE_RESIDUAL="${OUT_DWI}/${BIDS}_desc-denoiseResidual_dwi.nii.gz"
    if ! step_done 1 "débruitage MP-PCA (dwidenoise)"; then
        dwidenoise "$MIF_CONCAT" "$DWI_DENOISED" \
            -noise "$NOISE_MAP" \
            -nthreads "$NTHR" -force
        info "Carte de bruit : $(basename "$NOISE_MAP")"
        # Résidu pour QC (calculé ici pendant que DWI_DENOISED est disponible)
        if ! skip_if_exists "$DENOISE_RESIDUAL" "résidu dwidenoise"; then
            mrcalc "$MIF_CONCAT" "$DWI_DENOISED" -subtract "$DENOISE_RESIDUAL" \
                -nthreads "$NTHR" -force -quiet
        fi
        mark_done 1
    fi

    # ------------------------------------------------------------------
    # ÉTAPE 2 : Correction des anneaux de Gibbs (mrdegibbs)
    # -axes 0,1 : acquisition en plan axial
    # ------------------------------------------------------------------
    log "[2/10] Correction anneaux de Gibbs (mrdegibbs)"

    DWI_DEGIBBS="${TMP}/${BIDS}_dwi_desc-degibbs_dwi.mif"

    # Sentinelle : DWI_DEGIBBS est supprimé après l'étape 3
    if ! step_done 2 "correction anneaux de Gibbs (mrdegibbs)"; then
        mrdegibbs "$DWI_DENOISED" "$DWI_DEGIBBS" \
            -axes 0,1 \
            -nthreads "$NTHR" -force
        mark_done 2
    fi

    # Libérer l'espace : supprimer l'intermédiaire précédent
    [ -f "$DWI_DEGIBBS" ] && rm -f "$DWI_DENOISED"

    # ------------------------------------------------------------------
    # ÉTAPE 3 : Correction distorsion EPI + mouvement
    # (dwifslpreproc → FSL topup + eddy)
    # -rpe_pair  : paire AP+PA dédiée à topup (distincte des DWI)
    # -pe_dir AP : direction PE des DWI principaux
    # --repol    : remplacement des outliers par eddy
    # ------------------------------------------------------------------
    log "[3/10] Correction distorsion EPI (dwifslpreproc / topup+eddy)"

    DWI_PREPROC="${TMP}/${BIDS}_dwi_desc-preproc_dwi.mif"
    EDDY_DIR="${OUT_DWI}/eddy_qc"
    mkdir -p "$EDDY_DIR"

    # Sentinelle : DWI_PREPROC est supprimé après l'étape 4 (biascorr)
    # Sans sentinelle, eddy serait relacé inutilement à chaque re-run
    if ! step_done 3 "correction distorsion EPI (eddy)"; then
        dwifslpreproc "$DWI_DEGIBBS" "$DWI_PREPROC" \
            -pe_dir AP \
            -rpe_pair \
            -se_epi "$MIF_B0_PAIR" \
            -readout_time "$READOUT_TIME" \
            -eddy_options " --repol --slm=linear" \
            -eddyqc_all "$EDDY_DIR" \
            -nthreads "$NTHR" -force
        mark_done 3
    fi

    [ -f "$DWI_PREPROC" ] && rm -f "$DWI_DEGIBBS"

    # ------------------------------------------------------------------
    # ÉTAPE 4 : Correction biais B1 (dwibiascorrect ants)
    # Fallback : remplacer "ants" par "fsl" si ANTs non disponible
    # ------------------------------------------------------------------
    log "[4/10] Correction biais B1 (dwibiascorrect ants)"

    DWI_BIASCORR="${TMP}/${BIDS}_dwi_desc-biascorr_dwi.mif"
    BIAS_FIELD="${OUT_DWI}/${BIDS}_desc-biasField_dwi.nii.gz"

    # Sentinelle : DWI_BIASCORR est supprimé après l'étape 8 (FOD)
    if ! step_done 4 "correction biais B1 (dwibiascorrect)"; then
        # LD_LIBRARY_PATH restauré à sa valeur pré-FSL pour cet appel : voir
        # commentaire sur _LD_LIBRARY_PATH_PRE_FSL plus haut dans ce script.
        LD_LIBRARY_PATH="${_LD_LIBRARY_PATH_PRE_FSL}" dwibiascorrect ants "$DWI_PREPROC" "$DWI_BIASCORR" \
            -bias "$BIAS_FIELD" \
            -nthreads "$NTHR" -force
        mark_done 4
    fi

    [ -f "$DWI_BIASCORR" ] && rm -f "$DWI_PREPROC"

    # ------------------------------------------------------------------
    # ÉTAPE 4b : Upsampling DWI (mrgrid)
    # Recommandation MRtrix3 : 1.25 mm pour l'analyse fixel et la tractographie.
    # Position : après biascorrect, avant dwi2mask (résolution affecte le masque).
    # ------------------------------------------------------------------
    log "[4b/10] Upsampling DWI (mrgrid regrid -vox ${UPSAMPLE_VOX}mm)"

    DWI_UPSAMPLED="${TMP}/${BIDS}_dwi_desc-biascorr-upsampled_dwi.mif"

    # Sentinelle : DWI_UPSAMPLED est supprimé après l'étape 8 (FOD)
    if ! step_done 4b "upsampling DWI (mrgrid -vox ${UPSAMPLE_VOX}mm)"; then
        mrgrid "$DWI_BIASCORR" regrid \
            -vox "$UPSAMPLE_VOX" \
            "$DWI_UPSAMPLED" \
            -interp sinc \
            -nthreads "$NTHR" -force
        mark_done 4b
    fi

    # Libérer le fichier biascorrigé non upsampleé
    [ -f "$DWI_UPSAMPLED" ] && rm -f "$DWI_BIASCORR"

    # Les étapes suivantes utilisent le DWI upsampleé
    DWI_BIASCORR="$DWI_UPSAMPLED"

    # ------------------------------------------------------------------
    # ÉTAPE 5 : Masque cerveau (dwi2mask — MRtrix3)
    # ------------------------------------------------------------------
    log "[5/10] Masque cerveau (dwi2mask)"

    BRAIN_MASK="${OUT_DWI}/${BIDS}_space-dwi_desc-brain_mask.nii.gz"
    MEAN_B0="${OUT_DWI}/${BIDS}_desc-meanB0_dwi.nii.gz"

    # Mean b0 (référence spatiale pour la visualisation)
    if ! skip_if_exists "$MEAN_B0" "mean b0"; then
        dwiextract "$DWI_BIASCORR" - -bzero -nthreads "$NTHR" -quiet | \
            mrmath - mean "$MEAN_B0" -axis 3 -force -quiet
    fi

    if ! skip_if_exists "$BRAIN_MASK" "brain_mask.nii.gz"; then
        # Détection automatique de la syntaxe dwi2mask selon la version MRtrix3 :
        #   ≥ 3.0.4 : dwi2mask <algo> input output  (ex: legacy, fslbet, hdbet)
        #   < 3.0.4 : dwi2mask input output
        if dwi2mask --help 2>&1 | grep -q 'ALGORITHM'; then
            dwi2mask legacy "$DWI_BIASCORR" "$BRAIN_MASK" \
                -nthreads "$NTHR" -force
        else
            dwi2mask "$DWI_BIASCORR" "$BRAIN_MASK" \
                -nthreads "$NTHR" -force
        fi
    fi

    # ------------------------------------------------------------------
    # ÉTAPE 6 : Modèle tensoriel DTI (b=1000 uniquement)
    # On n'utilise pas b=2000 pour le tenseur (hypothèse gaussienne)
    # ------------------------------------------------------------------
    log "[6/10] Modèle tensoriel DTI (dwi2tensor / tensor2metric)"

    DWI_B1000_PREPROC="${TMP}/${BIDS}_dwi_shell-1000_preproc.mif"
    TENSOR="${TMP}/${BIDS}_model-DTI_tensor.mif"

    FA="${OUT_DWI}/${BIDS}_model-DTI_param-FA_dti.nii.gz"
    MD="${OUT_DWI}/${BIDS}_model-DTI_param-MD_dti.nii.gz"
    AD="${OUT_DWI}/${BIDS}_model-DTI_param-AD_dti.nii.gz"
    RD="${OUT_DWI}/${BIDS}_model-DTI_param-RD_dti.nii.gz"
    V1="${OUT_DWI}/${BIDS}_model-DTI_param-V1_dti.nii.gz"

    if ! skip_if_exists "$FA" "FA.nii.gz"; then
        dwiextract "$DWI_BIASCORR" "$DWI_B1000_PREPROC" \
            -shells 0,1000 \
            -nthreads "$NTHR" -force -quiet

        dwi2tensor "$DWI_B1000_PREPROC" "$TENSOR" \
            -mask "$BRAIN_MASK" \
            -nthreads "$NTHR" -force -quiet

        tensor2metric "$TENSOR" \
            -fa  "$FA" \
            -adc "$MD" \
            -ad  "$AD" \
            -rd  "$RD" \
            -vec "$V1" \
            -mask "$BRAIN_MASK" \
            -nthreads "$NTHR" -force -quiet

        rm -f "$DWI_B1000_PREPROC" "$TENSOR"
        info "FA, MD, AD, RD, V1 → ${OUT_DWI}/"
    fi

    # ------------------------------------------------------------------
    # ÉTAPE 7 : Estimation de la fonction de réponse (dhollander)
    # Algorithme MSMT, agnostique aux tissus (pas de 5TT requis)
    # ------------------------------------------------------------------
    log "[7/10] Estimation de la fonction de réponse (dwi2response dhollander)"

    RF_WM="${OUT_DWI}/${BIDS}_desc-dhollander_response-WM.txt"
    RF_GM="${OUT_DWI}/${BIDS}_desc-dhollander_response-GM.txt"
    RF_CSF="${OUT_DWI}/${BIDS}_desc-dhollander_response-CSF.txt"
    RF_VOXELS="${OUT_DWI}/${BIDS}_desc-dhollander_responseVoxels.nii.gz"

    if ! skip_if_exists "$RF_WM" "response WM"; then
        dwi2response dhollander "$DWI_BIASCORR" \
            "$RF_WM" "$RF_GM" "$RF_CSF" \
            -mask "$BRAIN_MASK" \
            -voxels "$RF_VOXELS" \
            -nthreads "$NTHR" -force
        info "Fonctions de réponse WM / GM / CSF estimées"
    fi

    # ------------------------------------------------------------------
    # ÉTAPE 8 : MSMT-CSD (dwi2fod msmt_csd)
    # Multi-shell Multi-Tissue : exploite les deux shells b=1000 et b=2000
    # ------------------------------------------------------------------
    log "[8/10] MSMT-CSD (dwi2fod msmt_csd)"

    FOD_WM="${TMP}/${BIDS}_desc-msmt_model-CSD_wm.mif"
    FOD_GM="${TMP}/${BIDS}_desc-msmt_model-CSD_gm.mif"
    FOD_CSF="${TMP}/${BIDS}_desc-msmt_model-CSD_csf.mif"

    # Sentinelle : FOD_WM est supprimé après l'étape 9 (mtnormalise)
    if ! step_done 8 "MSMT-CSD (dwi2fod)"; then
        dwi2fod msmt_csd "$DWI_BIASCORR" \
            -mask "$BRAIN_MASK" \
            "$RF_WM"  "$FOD_WM"  \
            "$RF_GM"  "$FOD_GM"  \
            "$RF_CSF" "$FOD_CSF" \
            -nthreads "$NTHR" -force
        info "FOD WM / GM / CSF calculés"
        mark_done 8
    fi

    # Libérer le volume DWI biascorrigé (plus gros fichier temporaire)
    [ -f "$FOD_WM" ] && rm -f "$DWI_BIASCORR"

    # ------------------------------------------------------------------
    # ÉTAPE 9 : Normalisation multi-tissue (mtnormalise)
    # Corrige les inhomogénéités d'intensité résiduelles inter-sujets
    # ------------------------------------------------------------------
    log "[9/10] Normalisation MT (mtnormalise)"

    FOD_WM_NORM="${OUT_DWI}/${BIDS}_desc-msmtNorm_model-CSD_wm.mif"
    FOD_GM_NORM="${OUT_DWI}/${BIDS}_desc-msmtNorm_model-CSD_gm.mif"
    FOD_CSF_NORM="${OUT_DWI}/${BIDS}_desc-msmtNorm_model-CSD_csf.mif"

    if ! skip_if_exists "$FOD_WM_NORM" "FOD WM normalisé"; then
        mtnormalise \
            "$FOD_WM"  "$FOD_WM_NORM"  \
            "$FOD_GM"  "$FOD_GM_NORM"  \
            "$FOD_CSF" "$FOD_CSF_NORM" \
            -mask "$BRAIN_MASK" \
            -nthreads "$NTHR" -force
        rm -f "$FOD_WM" "$FOD_GM" "$FOD_CSF"
        info "FODs normalisés"
    fi

    # Amplitude l0 WM (pour QC visualisation CSD)
    FOD_WM_AMP="${OUT_DWI}/${BIDS}_desc-msmtNorm_model-CSD_wmAmp.nii.gz"
    if ! skip_if_exists "$FOD_WM_AMP" "amplitude l0 FOD WM"; then
        mrconvert "$FOD_WM_NORM" - -coord 3 0 -axes 0,1,2 -force -quiet | \
            mrconvert - "$FOD_WM_AMP" -force -quiet
    fi

    # ------------------------------------------------------------------
    # ÉTAPE 10 : Tractographie iFOD2 + SIFT2
    # ------------------------------------------------------------------
    log "[10/10] Tractographie iFOD2 (tckgen) + SIFT2 (tcksift2)"

    TRACKS="${OUT_TRACT}/${BIDS}_desc-iFOD2_tractography.tck"
    SIFT2_WEIGHTS="${OUT_TRACT}/${BIDS}_desc-sift2_weights.csv"
    TRACKS_SIFT2_SAMPLE="${OUT_TRACT}/${BIDS}_desc-iFOD2sift2_200k.tck"

    if ! skip_if_exists "$TRACKS" "tractographie brute"; then
        tckgen "$FOD_WM_NORM" "$TRACKS" \
            -algorithm iFOD2 \
            -select "$N_STREAMLINES" \
            -seed_dynamic "$FOD_WM_NORM" \
            -mask "$BRAIN_MASK" \
            -cutoff 0.06 \
            -nthreads "$NTHR" -force
        info "${N_STREAMLINES} streamlines générés"
    fi

    if ! skip_if_exists "$SIFT2_WEIGHTS" "SIFT2 weights"; then
        tcksift2 "$TRACKS" "$FOD_WM_NORM" "$SIFT2_WEIGHTS" \
            -out_mu "${OUT_TRACT}/${BIDS}_desc-sift2_mu.txt" \
            -nthreads "$NTHR" -force
        info "Pondérations SIFT2 calculées"
    fi

    # Sous-échantillon pour visualisation (200k streamlines)
    if ! skip_if_exists "$TRACKS_SIFT2_SAMPLE" "tractographie 200k (visualisation)"; then
        tckedit "$TRACKS" "$TRACKS_SIFT2_SAMPLE" \
            -number 200000 \
            -tck_weights_in "$SIFT2_WEIGHTS" \
            -force -quiet
        info "Tractogramme 200k généré pour visualisation"
    fi

    # ------------------------------------------------------------------
    # QC : Figures de contrôle qualité
    # ------------------------------------------------------------------
    log "[QC] Génération des figures de contrôle qualité"

    python3 "${SCRIPT_DIR}/03_qc_plots.py" \
        --subject   "$SUBJECT_ID" \
        --out_dwi   "$OUT_DWI" \
        --out_plots "$OUT_PLOTS" \
        --mean_b0   "$MEAN_B0" \
        --mask      "$BRAIN_MASK" \
        --noise_map "$NOISE_MAP" \
        --residual  "$DENOISE_RESIDUAL" \
        --fa        "$FA" \
        --md        "$MD" \
        --fod_amp   "$FOD_WM_AMP" \
        --rf_wm     "$RF_WM" \
        --rf_gm     "$RF_GM" \
        --rf_csf    "$RF_CSF" \
        --eddy_dir  "$EDDY_DIR" \
        || warn "Figures QC non générées (vérifier 03_qc_plots.py)"

    log ">>> Sujet ${SUBJECT_ID} terminé — Résultats : ${RESULTS_ROOT}/${SUBJECT_ID}"

    if [ "$DO_PUSH" = true ]; then
        log "Push derivatives -> Garage (${SUBJECT_ID})"
        rclone copy "${RESULTS_ROOT}/${SUBJECT_ID}" \
            "${GARAGE_REMOTE}:${GARAGE_BUCKET}/${GARAGE_PREFIX}/derivatives/${PIPELINE}/${SUBJECT_ID}" \
            --exclude "*.mif" --exclude "tmp/**" --quiet
        rclone copy "$OUT_PLOTS" \
            "${GARAGE_REMOTE}:${GARAGE_BUCKET}/${GARAGE_PREFIX}/derivatives/plots/${SUBJECT_ID}" \
            --quiet
        info "Poussé vers Garage : derivatives/${PIPELINE}/${SUBJECT_ID} et derivatives/plots/${SUBJECT_ID}"
    fi

    if [ "$CLEAN_SOURCEDATA" = true ]; then
        rm -rf "$SUBJECT"
        info "Sourcedata locale supprimée : ${SUBJECT}"
    fi

done

# ===========================================================================
# QC récapitulatif tous sujets
# ===========================================================================
log "Génération du récapitulatif QC multi-sujets"

python3 "${SCRIPT_DIR}/03_qc_plots.py" \
    --summary \
    --results_root "$RESULTS_ROOT" \
    --out_plots    "$PLOTS_ROOT" \
    || warn "Récapitulatif QC non généré"

log "Pipeline ${PIPELINE} terminé."
echo ""
echo -e "${BOLD}Résultats :${RESET} ${RESULTS_ROOT}"
echo -e "${BOLD}Figures QC :${RESET} ${PLOTS_ROOT}"
