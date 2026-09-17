#!/bin/bash
# =============================================================================
# 06_tractseg_cerebellum.sh
# Tractographie bundle-spécifique (TractSeg) centrée sur le cervelet
# Dépendances : TractSeg (installé localement), MRtrix3, FSL
#
# Données d'entrée (issues de 02_mrtrix_pipeline.sh) :
#   derivatives/mrtrix/sub-XX/dwi/
#     sub-XX_desc-msmtNorm_model-CSD_wm.mif   (FOD WM normalisé)
#     sub-XX_model-DTI_param-FA_dti.nii.gz     (FA — pour recalage MNI)
#     sub-XX_space-dwi_desc-brain_mask.nii.gz  (masque cerveau)
#   ~/Data/Socosca/sub-XX/anat/T1.nii.gz       (T1 brut — pour recalage DeepCeres)
#   derivatives/deepceres/sub-XX/
#     native_structures_*.nii.gz               (atlas lobulaire DeepCeres, espace T1)
#     native_mask_*.nii.gz                     (masque cérébelleux DeepCeres, espace T1)
#
# Pipeline :
#   0. Extraction des pics CSD (sh2peaks depuis FOD WM → peaks.nii.gz 9 composantes)
#   1. Recalage DWI → MNI (FA + flirt 6 dof) pour TractSeg
#   2. TractSeg — segmentation des bundles (tract_segmentation)
#   3. TractSeg — régions d'extrémité (endings_segmentation)
#   4. TractSeg — Tract Orientation Maps (TOM)
#   5. Tracking bundle-spécifique (Tracking — probabiliste sur TOM)
#   6. Export des bundles en espace MNI (pas de retour DWI)
#   7. Filtrage : conserver uniquement les streamlines touchant le cervelet
#      (masque DeepCeres — tous labels > 0 recalé en espace MNI)
#   8. Statistiques de tractométrie par bundle
#
# Bundles cérébelleux TractSeg ciblés :
#   ICP_left / ICP_right  (pédoncule cérébelleux inférieur)
#   MCP                   (pédoncule cérébelleux moyen)
#   SCP_left / SCP_right  (pédoncule cérébelleux supérieur)
#   FPT_left / FPT_right  (tractus fronto-pontin — projections vers cervelet)
#   CST_left / CST_right  (tractus cortico-spinal — connexions indirectes)
#
# Masque cérébelleux ROI :
#   DeepCeres native_structures (tous labels > 0) recalé T1→MNI via ANTs
#
# Sorties :
#   derivatives/tractseg/sub-XX/
#     peaks/         peaks CSD en espace DWI et MNI
#     registration/  matrices de transformation DWI↔MNI
#     tractseg/      sorties brutes TractSeg (segmentations, TOM)
#     bundles/       tractogrammes .tck par bundle (espace MNI)
#     cerebellum/    masque cérébelleuse + tractogrammes filtrés
#     stats/         métriques DTI par bundle (TSV)
#
# Usage :
#   bash scripts/06_tractseg_cerebellum.sh [--sub sub-01] [--nthreads 8]
#   bash scripts/06_tractseg_cerebellum.sh --force   # tout recalculer
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Config machine
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../config/machine.sh"

if [ -f "${FSLDIR}/etc/fslconf/fsl.sh" ]; then
    set +eu
    # shellcheck disable=SC1090
    source "${FSLDIR}/etc/fslconf/fsl.sh"
    set -eu
fi

# ---------------------------------------------------------------------------
# Valeurs par défaut
# ---------------------------------------------------------------------------
DATA_DIR="${HOME}/Data/Socosca"
EXP_DIR="${HOME}/Exp/socosca"
MRTRIX_RESULTS="${EXP_DIR}/derivatives/mrtrix"
RESULTS_ROOT="${EXP_DIR}/derivatives/tractseg"

SKIP_EXISTING="${SKIP_EXISTING:-true}"
NTHR="${NTHR_DEFAULT}"
SUBJECT_ARG=""

# Bundles cérébelleux à traiter (séparés par des virgules pour TractSeg/Tracking)
CEREB_BUNDLES="ICP_left,ICP_right,MCP,SCP_left,SCP_right,FPT_left,FPT_right"


# Bundles QC classiques (pour vérification qualité du pipeline)
QC_BUNDLES="CST_left,CST_right,AF_left,AF_right"

# Segmentation cérébelleuse DeepCeres
DEEPCERES_RESULTS="${EXP_DIR}/derivatives/deepceres"

# ---------------------------------------------------------------------------
# Parsing des arguments
# ---------------------------------------------------------------------------
usage() {
    cat <<EOF
Usage: $(basename "$0") [--sub <id>] [--nthreads <n>] [--force] [--help]

  --sub       traiter un seul sujet (ex: sub-01)
  --nthreads  nombre de threads MRtrix3 (défaut: ${NTHR})
  --force     relancer tous les calculs même si les résultats existent
  --help      afficher cette aide

Bundles traités : ${CEREB_BUNDLES}
EOF
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --sub)       SUBJECT_ARG="$2"; shift 2 ;;
        --nthreads)  NTHR="$2";        shift 2 ;;
        --force)     SKIP_EXISTING="false"; shift ;;
        --help|-h)   usage ;;
        *)           echo "Argument inconnu : $1"; exit 1 ;;
    esac
done

# ---------------------------------------------------------------------------
# Correctif macOS : conflit libomp + segfault PyTorch multiprocessing
# - KMP_DUPLICATE_LIB_OK : évite l'"Abort trap: 6" (double init libomp)
# - OMP/MKL/OPENBLAS NUM_THREADS=1 : force le mode single-thread PyTorch
#   pour éviter le segfault joblib/loky sur macOS ARM64
# - PYTORCH_ENABLE_MPS_FALLBACK : repli CPU si une op MPS échoue
# ---------------------------------------------------------------------------
export KMP_DUPLICATE_LIB_OK=TRUE
export OMP_NUM_THREADS=1
export MKL_NUM_THREADS=1
export OPENBLAS_NUM_THREADS=1
export NUMEXPR_NUM_THREADS=1
export PYTORCH_ENABLE_MPS_FALLBACK=1
# Python 3.12 macOS : multiprocessing utilise "spawn" par défaut au lieu de "fork".
# Les workers spawn ne partagent pas la mémoire → variables globales (peaks) = None.
# OBJC_DISABLE_INITIALIZE_FORK_SAFETY=YES réactive fork sur macOS.
export OBJC_DISABLE_INITIALIZE_FORK_SAFETY=YES

# ---------------------------------------------------------------------------
# Vérification des dépendances
# ---------------------------------------------------------------------------
for cmd in TractSeg Tracking sh2peaks flirt mrconvert tckmap tckedit python3 antsRegistrationSyN.sh antsApplyTransforms; do
    if ! command -v "$cmd" &>/dev/null; then
        echo "[ERR] Commande introuvable : ${cmd}" >&2
        [ "$cmd" = "TractSeg" ] && echo "  → Installer via : pip install TractSeg" >&2
        [ "$cmd" = "Tracking" ] && echo "  → Fourni avec TractSeg" >&2
        [ "$cmd" = "antsRegistrationSyN.sh" ] && echo "  → ANTs requis : ~/Code/ants-2.5.4/bin" >&2
        exit 1
    fi
done

mkdir -p "$RESULTS_ROOT"

# ---------------------------------------------------------------------------
# Fonctions utilitaires
# ---------------------------------------------------------------------------
BOLD="\033[1m"
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

skip_if_dir_exists() {
    local dir="$1" label="${2:-$(basename "$1")}"
    if [ "${SKIP_EXISTING}" = "true" ] && [ -d "$dir" ] && [ "$(ls -A "$dir" 2>/dev/null)" ]; then
        echo -e "  ${YELLOW}[SKIP]${RESET} ${label}"
        return 0
    fi
    return 1
}

# Vérifie que l'en-tête géométrique d'un tractogramme est cohérent avec
# l'image de référence (dimensions voxel-grid identiques).
assert_tck_space_matches_image() {
    local tck="$1"
    local img="$2"
    local label="$3"

    local tck_dims img_dims
    tck_dims=$(tckinfo "$tck" 2>/dev/null | awk -F'[()]' '/dimensions:/ {gsub(/ /, "", $2); print $2; exit}')
    img_dims=$(mrinfo "$img" -size 2>/dev/null | awk '{print $1","$2","$3}')

    if [ -z "$tck_dims" ] || [ -z "$img_dims" ]; then
        warn "${label}: impossible de lire les dimensions (tck=${tck_dims:-NA}, img=${img_dims:-NA})"
        return 1
    fi

    if [ "$tck_dims" != "$img_dims" ]; then
        warn "${label}: dimensions incompatibles (tck=${tck_dims}, img=${img_dims})"
        return 1
    fi
    return 0
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

log "Pipeline TractSeg cervelet — ${#SUBJECTS[@]} sujet(s) | threads=${NTHR} | skip_existing=${SKIP_EXISTING}"
log "Bundles : ${CEREB_BUNDLES}"

# ===========================================================================
# BOUCLE PAR SUJET
# ===========================================================================
for SUBJECT_ID in "${SUBJECTS[@]}"; do

    log "========================================================"
    log " SUJET : ${SUBJECT_ID}"
    log "========================================================"

    # ------------------------------------------------------------------
    # Entrées MRtrix
    # ------------------------------------------------------------------
    IN_DWI="${MRTRIX_RESULTS}/${SUBJECT_ID}/dwi"
    FOD_WM="${IN_DWI}/${SUBJECT_ID}_desc-msmtNorm_model-CSD_wm.mif"
    FA="${IN_DWI}/${SUBJECT_ID}_model-DTI_param-FA_dti.nii.gz"
    BRAIN_MASK="${IN_DWI}/${SUBJECT_ID}_space-dwi_desc-brain_mask.nii.gz"

    [ -f "$FOD_WM" ]     || die "${SUBJECT_ID} : FOD WM normalisé introuvable (${FOD_WM})\n  → Lancer 02_mrtrix_pipeline.sh d'abord"
    [ -f "$FA" ]         || die "${SUBJECT_ID} : FA introuvable (${FA})"
    [ -f "$BRAIN_MASK" ] || die "${SUBJECT_ID} : masque cerveau introuvable (${BRAIN_MASK})"

    # ------------------------------------------------------------------
    # Entrées DeepCeres (masque et atlas lobulaire en espace T1 natif)
    # ------------------------------------------------------------------
    DEPC_DIR="${DEEPCERES_RESULTS}/${SUBJECT_ID}"
    DEPC_STRUCT_NAT=$(ls "${DEPC_DIR}"/native_structures_*.nii.gz 2>/dev/null | head -1 || true)
    DEPC_MASK_NAT=$(ls  "${DEPC_DIR}"/native_mask_*.nii.gz        2>/dev/null | head -1 || true)
    T1_ORIG="${DATA_DIR}/${SUBJECT_ID}/anat/T1.nii.gz"

    [ -n "$DEPC_STRUCT_NAT" ] || die "${SUBJECT_ID} : DeepCeres native_structures introuvable dans ${DEPC_DIR}"
    [ -n "$DEPC_MASK_NAT" ]   || die "${SUBJECT_ID} : DeepCeres native_mask introuvable dans ${DEPC_DIR}"
    [ -f "$T1_ORIG" ]          || die "${SUBJECT_ID} : T1.nii.gz introuvable (${T1_ORIG})"

    # ------------------------------------------------------------------
    # Répertoires de sortie
    # ------------------------------------------------------------------
    OUT="${RESULTS_ROOT}/${SUBJECT_ID}"
    OUT_PEAKS="${OUT}/peaks"
    OUT_REG="${OUT}/registration"
    OUT_TS="${OUT}/tractseg"
    OUT_BUNDLES="${OUT}/bundles"
    OUT_CEREB="${OUT}/cerebellum"
    OUT_STATS="${OUT}/stats"

    mkdir -p "$OUT_PEAKS" "$OUT_REG" "$OUT_TS" "$OUT_BUNDLES" "$OUT_CEREB" "$OUT_STATS"

    # ------------------------------------------------------------------
    # ÉTAPE 0 : Extraction des pics CSD depuis le FOD WM
    # TractSeg attend peaks.nii.gz de shape [x,y,z,9] (3 pics × xyz)
    # ------------------------------------------------------------------
    log "[0/8] Extraction des pics CSD (sh2peaks)"

    PEAKS_DWI="${OUT_PEAKS}/${SUBJECT_ID}_space-dwi_peaks.nii.gz"

    if ! skip_if_exists "$PEAKS_DWI" "peaks CSD (espace DWI)"; then
        sh2peaks "$FOD_WM" "$PEAKS_DWI" \
            -num 3 \
            -mask "$BRAIN_MASK" \
            -nthreads "$NTHR" -force
        info "Pics CSD extraits : $(mrinfo "$PEAKS_DWI" -size)"
    fi

    # ------------------------------------------------------------------
    # ÉTAPE 1 : Recalage FA → MNI (ANTs SyN : rigid + affine + déformable)
    # TractSeg exige une orientation MNI (même espace que HCP).
    # ANTs SyN corrige les distorsions locales impossibles à capturer par
    # un recalage linéaire, améliorant la détection des bundles cérébelleux.
    # Note : --preprocess n'est utilisé que pour tract_segmentation/endings.
    # Pour TOM + Tracking, un recalage manuel est requis.
    # ------------------------------------------------------------------
    log "[1/8] Recalage FA → MNI (ANTs SyN)"

    MNI_TEMPLATE="${FSLDIR}/data/standard/MNI152_T1_1mm_brain.nii.gz"
    [ -f "$MNI_TEMPLATE" ] || MNI_TEMPLATE="${FSLDIR}/data/standard/MNI152_T1_2mm_brain.nii.gz"
    [ -f "$MNI_TEMPLATE" ] || die "Template MNI introuvable dans ${FSLDIR}/data/standard/"

    FA_MNI="${OUT_REG}/${SUBJECT_ID}_space-MNI_FA.nii.gz"
    ANTS_PREFIX="${OUT_REG}/${SUBJECT_ID}_dwi2mni_"
    ANTS_AFFINE="${ANTS_PREFIX}0GenericAffine.mat"
    ANTS_WARP="${ANTS_PREFIX}1Warp.nii.gz"
    ANTS_INV_WARP="${ANTS_PREFIX}1InverseWarp.nii.gz"
    PEAKS_MNI="${OUT_PEAKS}/${SUBJECT_ID}_space-MNI_peaks.nii.gz"
    MASK_MNI="${OUT_REG}/${SUBJECT_ID}_space-MNI_desc-brain_mask.nii.gz"

    if ! skip_if_exists "$ANTS_AFFINE" "registration ANTs SyN DWI→MNI"; then
        antsRegistrationSyN.sh \
            -d 3 \
            -f "$MNI_TEMPLATE" \
            -m "$FA" \
            -o "$ANTS_PREFIX" \
            -t s \
            -n "$NTHR"
        # Warped.nii.gz = FA recalée en MNI
        mv "${ANTS_PREFIX}Warped.nii.gz"        "$FA_MNI"
        rm -f "${ANTS_PREFIX}InverseWarped.nii.gz"
        info "ANTs SyN DWI→MNI terminée : ${ANTS_AFFINE}"
    fi

    # Générer FA_MNI si absent (run repris après suppression manuelle)
    if ! skip_if_exists "$FA_MNI" "FA recalée en MNI"; then
        antsApplyTransforms \
            -d 3 \
            -i "$FA" \
            -o "$FA_MNI" \
            -r "$MNI_TEMPLATE" \
            -t "$ANTS_WARP" \
            -t "$ANTS_AFFINE" \
            --interpolation Linear
    fi

    # Recaler les pics dans l'espace MNI (time-series : un volume par composante)
    if ! skip_if_exists "$PEAKS_MNI" "peaks CSD (espace MNI)"; then
        antsApplyTransforms \
            -d 3 \
            --input-image-type 3 \
            -i "$PEAKS_DWI" \
            -o "$PEAKS_MNI" \
            -r "$MNI_TEMPLATE" \
            -t "$ANTS_WARP" \
            -t "$ANTS_AFFINE" \
            --interpolation Linear
        info "Pics recalés vers MNI (ANTs)"
    fi

    # Recaler le masque cerveau dans l'espace MNI
    if ! skip_if_exists "$MASK_MNI" "masque cerveau (espace MNI)"; then
        antsApplyTransforms \
            -d 3 \
            -i "$BRAIN_MASK" \
            -o "$MASK_MNI" \
            -r "$MNI_TEMPLATE" \
            -t "$ANTS_WARP" \
            -t "$ANTS_AFFINE" \
            --interpolation NearestNeighbor
    fi

    # ------------------------------------------------------------------
    # ÉTAPE 2 : TractSeg — segmentation des bundles (tract_segmentation)
    # ------------------------------------------------------------------
    log "[2/8] TractSeg — segmentation des bundles (tract_segmentation)"

    TS_TRACT_DIR="${OUT_TS}/bundle_segmentations"

    if ! skip_if_dir_exists "$TS_TRACT_DIR" "segmentations TractSeg"; then
        TractSeg \
            -i      "$PEAKS_MNI" \
            -o      "$OUT_TS" \
            --output_type tract_segmentation \
            --brain_mask "$MASK_MNI" \
            --nr_cpus 1
        info "Segmentations de bundles créées dans ${TS_TRACT_DIR}"
    fi

    # ------------------------------------------------------------------
    # ÉTAPE 3 : TractSeg — régions d'extrémité (endings_segmentation)
    # ------------------------------------------------------------------
    log "[3/8] TractSeg — régions d'extrémité (endings_segmentation)"

    TS_END_DIR="${OUT_TS}/endings_segmentations"

    if ! skip_if_dir_exists "$TS_END_DIR" "endings TractSeg"; then
        TractSeg \
            -i      "$PEAKS_MNI" \
            -o      "$OUT_TS" \
            --output_type endings_segmentation \
            --brain_mask "$MASK_MNI" \
            --nr_cpus 1
        info "Masques d'extrémité créés dans ${TS_END_DIR}"
    fi

    # ------------------------------------------------------------------
    # ÉTAPE 4 : TractSeg — Tract Orientation Maps (TOM)
    # ------------------------------------------------------------------
    log "[4/8] TractSeg — Tract Orientation Maps (TOM)"

    TS_TOM_DIR="${OUT_TS}/TOM"

    if ! skip_if_dir_exists "$TS_TOM_DIR" "TOM TractSeg"; then
        TractSeg \
            -i      "$PEAKS_MNI" \
            -o      "$OUT_TS" \
            --output_type TOM \
            --brain_mask "$MASK_MNI" \
            --nr_cpus 1
        info "TOM créés dans ${TS_TOM_DIR}"
    fi

    # ------------------------------------------------------------------
    # ÉTAPE 5 : Tracking bundle-spécifique (Tracking sur TOM)
    # Utilise le suivi probabiliste sur les TOM (défaut TractSeg)
    # ------------------------------------------------------------------
    log "[5/8] Tracking bundle-spécifique (Tracking sur TOM)"

    TS_TRACK_DIR="${OUT_TS}/TOM_trackings"

    if ! skip_if_dir_exists "$TS_TRACK_DIR" "tractogrammes TractSeg (MNI)"; then
        Tracking \
            -i      "$PEAKS_MNI" \
            -o      "$OUT_TS" \
            --bundles "$CEREB_BUNDLES" \
            --tracking_format tck \
            --nr_cpus 1
        info "Tractogrammes bundle-spécifiques dans ${TS_TRACK_DIR}"
    fi

    # ------------------------------------------------------------------
    # ÉTAPE 6 : Export bundles en espace MNI (cohérence stricte)
    # Le retour MNI→DWI par champ custom est désactivé car non robuste.
    # ------------------------------------------------------------------
    log "[6/8] Export des bundles en espace MNI"

    IFS=',' read -ra BUNDLE_LIST <<< "$CEREB_BUNDLES"

    for BUNDLE in "${BUNDLE_LIST[@]}"; do
        TCK_MNI="${TS_TRACK_DIR}/${BUNDLE}.tck"
        TCK_OUT_MNI="${OUT_BUNDLES}/${SUBJECT_ID}_bundle-${BUNDLE}_space-MNI.tck"

        [ -f "$TCK_MNI" ] || { warn "Tractogramme introuvable : ${TCK_MNI}"; continue; }

        if ! skip_if_exists "$TCK_OUT_MNI" "bundle ${BUNDLE} (espace MNI)"; then
            tckedit "$TCK_MNI" "$TCK_OUT_MNI" -force -quiet
        fi

        assert_tck_space_matches_image "$TCK_OUT_MNI" "$FA_MNI" "${SUBJECT_ID}/${BUNDLE}" \
            || die "${SUBJECT_ID} : incohérence espace MNI détectée pour ${BUNDLE}"
        info "${BUNDLE} (MNI) : $(tckinfo "$TCK_OUT_MNI" | awk -F': *' '/count:/ {print $2; exit}') streamlines"
    done

    # ------------------------------------------------------------------
    # ÉTAPE 7 : Masque cérébelleux DeepCeres en MNI + filtrage bundles
    # ------------------------------------------------------------------
    log "[7/8] Filtrage par ROI cérébelleuse (DeepCeres en MNI)"

    DEPC_BRAIN_T1="${OUT_REG}/${SUBJECT_ID}_space-T1w_desc-brain_T1w.nii.gz"
    DEPC_STRUCT_MNI="${OUT_CEREB}/${SUBJECT_ID}_space-MNI_desc-deepceres_dseg.nii.gz"
    CEREB_MASK_MNI="${OUT_CEREB}/${SUBJECT_ID}_space-MNI_desc-deepceres-all_mask.nii.gz"

    # 1. Brain-extract T1 avec le masque DeepCeres
    if ! skip_if_exists "$DEPC_BRAIN_T1" "T1 brain-extracted (masque DeepCeres)"; then
        python3 - <<PYEOF
import nibabel as nib, numpy as np
import nibabel.processing as nbp
t1 = nib.load("${T1_ORIG}")
mask = nib.load("${DEPC_MASK_NAT}")
mask_res = nbp.resample_from_to(mask, t1, order=0)
out = (t1.get_fdata() * (mask_res.get_fdata() > 0)).astype(np.float32)
nib.save(nib.Nifti1Image(out, t1.affine, t1.header), "${DEPC_BRAIN_T1}")
print(f"  T1 brain-extracted : {int((out > 0).sum())} voxels non nuls")
PYEOF
        info "T1 brain-extracted : ${DEPC_BRAIN_T1}"
    fi

    # 2. Registration T1→DWI (rigide) pour chaîner T1→DWI→MNI
    ANTS_RIGID_PREFIX="${OUT_REG}/${SUBJECT_ID}_from-T1-to-dwi_"
    ANTS_RIGID_MAT="${ANTS_RIGID_PREFIX}0GenericAffine.mat"

    if ! skip_if_exists "$ANTS_RIGID_MAT" "transformation ANTs rigid T1→DWI"; then
        rm -f "${ANTS_RIGID_PREFIX}"*
        antsRegistrationSyN.sh \
            -d 3 \
            -f "$FA" \
            -m "$DEPC_BRAIN_T1" \
            -o "$ANTS_RIGID_PREFIX" \
            -t r \
            -n "$NTHR" \
            -p f \
            -e 1 \
            > /tmp/ants_rigid_${SUBJECT_ID}.log 2>&1 \
            || die "${SUBJECT_ID} : ANTs rigid T1→DWI échoué (voir /tmp/ants_rigid_${SUBJECT_ID}.log)"
        [ -f "$ANTS_RIGID_MAT" ] || die "${SUBJECT_ID} : matrice ANTs rigid absente après registration"
        info "Transformation ANTs rigid T1→DWI : ${ANTS_RIGID_MAT}"
    fi

    # 3. Recaler l'atlas DeepCeres de T1 vers MNI (via T1→DWI puis DWI→MNI)
    if ! skip_if_exists "$DEPC_STRUCT_MNI" "atlas DeepCeres (espace MNI)"; then
        antsApplyTransforms \
            -d 3 \
            -r "$MNI_TEMPLATE" \
            -i "$DEPC_STRUCT_NAT" \
            -o "$DEPC_STRUCT_MNI" \
            -n NearestNeighbor \
            -t "$ANTS_WARP" \
            -t "$ANTS_AFFINE" \
            -t "$ANTS_RIGID_MAT"
        info "Atlas DeepCeres recalé en espace MNI : ${DEPC_STRUCT_MNI}"
    fi

    # 4. Masque binaire MNI = tous labels > 0
    if ! skip_if_exists "$CEREB_MASK_MNI" "masque cérébelleux complet (MNI)"; then
        python3 - <<PYEOF
import nibabel as nib, numpy as np
s = nib.load("${DEPC_STRUCT_MNI}")
mask = (s.get_fdata() > 0).astype(np.uint8)
nib.save(nib.Nifti1Image(mask, s.affine, s.header), "${CEREB_MASK_MNI}")
print(f"  Masque DeepCeres complet (MNI) : {int(mask.sum())} voxels")
PYEOF
        info "Masque cérébelleux DeepCeres : ${CEREB_MASK_MNI}"
    fi

    # 5. Filtrage bundles en espace MNI
    for BUNDLE in "${BUNDLE_LIST[@]}"; do
        TCK_MNI="${OUT_BUNDLES}/${SUBJECT_ID}_bundle-${BUNDLE}_space-MNI.tck"
        TCK_CEREB="${OUT_CEREB}/${SUBJECT_ID}_bundle-${BUNDLE}_space-MNI_cerebellar.tck"
        TCK_DENSITY="${OUT_CEREB}/${SUBJECT_ID}_bundle-${BUNDLE}_space-MNI_density.nii.gz"

        [ -f "$TCK_MNI" ] || { warn "Tractogramme MNI introuvable pour ${BUNDLE}"; continue; }

        if ! skip_if_exists "$TCK_CEREB" "filtrage cérébelleux ${BUNDLE}"; then
            tckedit "$TCK_MNI" "$TCK_CEREB" -include "$CEREB_MASK_MNI" -force -quiet
            assert_tck_space_matches_image "$TCK_CEREB" "$FA_MNI" "${SUBJECT_ID}/${BUNDLE}/cerebellar" \
                || die "${SUBJECT_ID} : incohérence espace MNI après filtrage ${BUNDLE}"
            N=$(tckinfo "$TCK_CEREB" 2>/dev/null | awk -F': *' '/count:/ {print $2; exit}' || echo "?")
            info "${BUNDLE} cérébelleux (MNI) : ${N} streamlines"
        fi

        if ! skip_if_exists "$TCK_DENSITY" "densité ${BUNDLE}"; then
            tckmap "$TCK_CEREB" "$TCK_DENSITY" -template "$FA_MNI" -force -quiet
        fi
    done

    # TDI globale en MNI
    TCK_ALL_CEREB="${OUT_CEREB}/${SUBJECT_ID}_all-cerebellar_space-MNI.tck"
    TDI_ALL_CEREB="${OUT_CEREB}/${SUBJECT_ID}_tdi-all-cerebellar_space-MNI.nii.gz"

    if ! skip_if_exists "$TCK_ALL_CEREB" "fusion tous bundles cérébelleux"; then
        CEREB_TCKS=()
        for BUNDLE in "${BUNDLE_LIST[@]}"; do
            TCK_CEREB="${OUT_CEREB}/${SUBJECT_ID}_bundle-${BUNDLE}_space-MNI_cerebellar.tck"
            [ -f "$TCK_CEREB" ] && CEREB_TCKS+=("$TCK_CEREB")
        done
        if [ "${#CEREB_TCKS[@]}" -gt 0 ]; then
            tckedit "${CEREB_TCKS[@]}" "$TCK_ALL_CEREB" -force -quiet
            N_ALL=$(tckinfo "$TCK_ALL_CEREB" 2>/dev/null | awk -F': *' '/count:/ {print $2; exit}' || echo "?")
            info "Fusion cérébelleux (MNI) : ${N_ALL} streamlines → ${TCK_ALL_CEREB}"
        else
            warn "Aucun bundle cérébelleux disponible pour la fusion"
        fi
    fi

    if ! skip_if_exists "$TDI_ALL_CEREB" "TDI globale cérébelleux"; then
        [ -f "$TCK_ALL_CEREB" ] && \
        tckmap "$TCK_ALL_CEREB" "$TDI_ALL_CEREB" -template "$FA_MNI" -force -quiet && \
        info "TDI globale cérébelleux (MNI) : ${TDI_ALL_CEREB}"
    fi

    # ------------------------------------------------------------------
    # ÉTAPE 8 : Tableau QC des bundles (espace MNI uniquement)
    # Les métriques DTI voxelwise sont désactivées ici pour éviter tout
    # mélange d'espaces (FA/MD/AD/RD sont en espace DWI natif).
    # ------------------------------------------------------------------
    log "[8/8] Tableau QC des bundles (MNI)"

    STATS_TSV="${OUT_STATS}/${SUBJECT_ID}_tractseg_cerebellum_stats.tsv"

    if ! skip_if_exists "$STATS_TSV" "tableau QC bundles"; then
        python3 - <<PYEOF
import csv, os
import nibabel as nib

subject = "${SUBJECT_ID}"
bundles = [b.strip() for b in "${CEREB_BUNDLES}".split(",")]
out_dir = "${OUT_CEREB}"
rows = []

for bundle in bundles:
    tck_file = os.path.join(out_dir, f"{subject}_bundle-{bundle}_space-MNI_cerebellar.tck")
    density_file = os.path.join(out_dir, f"{subject}_bundle-{bundle}_space-MNI_density.nii.gz")
    if not os.path.isfile(tck_file):
        continue

    # Lecture du count via header MRtrix (fallback NA)
    count = "NA"
    try:
        import subprocess
        r = subprocess.run(["tckinfo", tck_file], capture_output=True, text=True, check=False)
        for line in r.stdout.splitlines():
            if line.strip().startswith("count:"):
                count = line.split(":", 1)[1].strip()
                break
    except Exception:
        pass

    n_vox = "NA"
    if os.path.isfile(density_file):
        d = nib.load(density_file).get_fdata()
        n_vox = int((d > 0).sum())

    rows.append({
        "subject": subject,
        "bundle": bundle,
        "space": "MNI",
        "streamlines": count,
        "density_nonzero_voxels": n_vox,
        "note": "DTI metrics skipped to avoid cross-space bias"
    })

if rows:
    with open("${STATS_TSV}", "w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=list(rows[0].keys()), delimiter="\t")
        writer.writeheader()
        writer.writerows(rows)
    print(f"  Tableau QC sauvegardé : ${STATS_TSV}")
else:
    print("  [WARN] Aucune statistique calculée")
PYEOF
        info "Tableau QC par bundle → ${STATS_TSV}"
    fi

    # ------------------------------------------------------------------
    # ÉTAPE 9 : Bundles QC (CST + AF) en espace MNI
    # TractSeg TOM déjà calculés pour tous les bundles à l'étape 4
    # ------------------------------------------------------------------
    log "[9/12] Bundles QC (CST + AF) — export MNI"

    OUT_FIGS="${OUT}/figures"
    mkdir -p "$OUT_FIGS"

    QC_TRACK_SENTINEL="${TS_TRACK_DIR}/CST_left.tck"
    if ! skip_if_exists "$QC_TRACK_SENTINEL" "tractogrammes QC CST+AF (MNI)"; then
        Tracking \
            -i      "$PEAKS_MNI" \
            -o      "$OUT_TS" \
            --bundles "$QC_BUNDLES" \
            --tracking_format tck \
            --nr_cpus 1
        info "Tractogrammes QC dans ${TS_TRACK_DIR}"
    fi

    for BUNDLE in CST_left CST_right AF_left AF_right; do
        TCK_MNI="${TS_TRACK_DIR}/${BUNDLE}.tck"
        TCK_MNI_OUT="${OUT_BUNDLES}/${SUBJECT_ID}_bundle-${BUNDLE}_space-MNI.tck"
        [ -f "$TCK_MNI" ] || { warn "Tractogramme QC introuvable : ${TCK_MNI}"; continue; }
        if ! skip_if_exists "$TCK_MNI_OUT" "bundle QC ${BUNDLE} (espace MNI)"; then
            tckedit "$TCK_MNI" "$TCK_MNI_OUT" -force -quiet
            assert_tck_space_matches_image "$TCK_MNI_OUT" "$FA_MNI" "${SUBJECT_ID}/${BUNDLE}/QC" \
                || die "${SUBJECT_ID}/${BUNDLE} : incohérence espace MNI (QC)"
            info "${BUNDLE} (MNI QC) : $(tckinfo "$TCK_MNI_OUT" | awk -F': *' '/count:/ {print $2; exit}') streamlines"
        fi
    done

    # ------------------------------------------------------------------
    # ÉTAPE 10 : Atlas DeepCeres par lobule (espace MNI)
    # DEPC_STRUCT_MNI et CEREB_MASK_MNI sont définis à l'étape 7.
    # ------------------------------------------------------------------
    log "[10/12] Atlas DeepCeres lobulaire (espace MNI)"

    # Tableaux parallèles : labels D (1-12) et noms des lobules
    # Labels G = label D + 100 ; labels 13 / 113 = WM (non utilisé pour figures)
    LOBULE_IDXS=(1 2 3 4 5 6 7 8 9 10 11 12)
    LOBULE_NAMS=("LobI-II" "LobIII" "LobIV" "LobV" "LobVI" "CrusI" "CrusII" "LobVIIB" "LobVIIIA" "LobVIIIB" "LobIX" "LobX")

    DEEPCERES_OK=false
    OUT_LOBULES="${OUT_CEREB}/per_lobule"

    if [ -f "$DEPC_STRUCT_MNI" ]; then
        DEEPCERES_OK=true
    else
        warn "${SUBJECT_ID} : DEPC_STRUCT_MNI absent (${DEPC_STRUCT_MNI}) — étapes 10-12 ignorées"
    fi

    # ------------------------------------------------------------------
    # ÉTAPE 11 : Filtrage des tracts par lobule cérébelleux DeepCeres
    # Pour chaque lobule bilatéral : masque binaire DWI → tckedit --include
    # ------------------------------------------------------------------
    if [ "$DEEPCERES_OK" = "true" ]; then

        # TDI globale basée sur le masque cérébelleux complet DeepCeres
        # (CEREB_MASK_MNI = tous labels > 0, calculé à l'étape 7)
        TCK_DEPC_ALL="${OUT_CEREB}/${SUBJECT_ID}_all-cerebellar-deepceres.tck"
        TDI_DEPC_ALL="${OUT_CEREB}/${SUBJECT_ID}_tdi-deepceres-cerebellum.nii.gz"

        if ! skip_if_exists "$TDI_DEPC_ALL" "TDI cérébelleux complet DeepCeres"; then
            if [ -f "$TCK_ALL_CEREB" ] && [ -f "$CEREB_MASK_MNI" ]; then
                tckedit "$TCK_ALL_CEREB" "$TCK_DEPC_ALL" -include "$CEREB_MASK_MNI" -force -quiet
                tckmap "$TCK_DEPC_ALL" "$TDI_DEPC_ALL" \
                    -template "$FA_MNI" -force -quiet
                N_DEPC=$(tckinfo "$TCK_DEPC_ALL" 2>/dev/null | grep ' count' | awk '{print $NF}' || echo "?")
                info "TDI DeepCeres cervelet : ${N_DEPC} streamlines → ${TDI_DEPC_ALL}"
            else
                warn "TDI DeepCeres ignorée : ${TCK_ALL_CEREB} ou ${CEREB_MASK_MNI} manquant"
            fi
        fi

        log "[11/12] Filtrage des tracts par lobule DeepCeres"
        mkdir -p "$OUT_LOBULES"
        IFS=',' read -ra BUNDLE_LIST <<< "$CEREB_BUNDLES"

        for IDX in "${!LOBULE_IDXS[@]}"; do
            LABEL_R="${LOBULE_IDXS[$IDX]}"
            LABEL_L=$((LABEL_R + 100))
            LOB_NAME="${LOBULE_NAMS[$IDX]}"
            LOB_MASK="${OUT_LOBULES}/${SUBJECT_ID}_desc-deepceres-${LOB_NAME}_mask.nii.gz"

            if ! skip_if_exists "$LOB_MASK" "masque ${LOB_NAME} bilatéral"; then
                python3 - <<PYEOF
import nibabel as nib, numpy as np
s = nib.load("${DEPC_STRUCT_MNI}")
d = s.get_fdata()
mask = ((d == ${LABEL_R}) | (d == ${LABEL_L})).astype(np.uint8)
nib.save(nib.Nifti1Image(mask, s.affine, s.header), "${LOB_MASK}")
print(f"  ${LOB_NAME} (labels ${LABEL_R}+${LABEL_L}): {int(mask.sum())} voxels")
PYEOF
            fi

            N_MASK=$(python3 -c "
import nibabel as nib, numpy as np
print(int(nib.load('${LOB_MASK}').get_fdata().sum()))" 2>/dev/null || echo 0)
            [ "${N_MASK:-0}" -gt 0 ] || continue

            for BUNDLE in "${BUNDLE_LIST[@]}"; do
                TCK_IN="${OUT_BUNDLES}/${SUBJECT_ID}_bundle-${BUNDLE}_space-MNI.tck"
                TCK_OUT="${OUT_LOBULES}/${SUBJECT_ID}_bundle-${BUNDLE}_desc-deepceres-${LOB_NAME}.tck"
                [ -f "$TCK_IN" ] || continue
                if ! skip_if_exists "$TCK_OUT" "${LOB_NAME} × ${BUNDLE}"; then
                    tckedit "$TCK_IN" "$TCK_OUT" -include "$LOB_MASK" -force -quiet
                    N_TCK=$(tckinfo "$TCK_OUT" 2>/dev/null | grep ' count' | awk '{print $NF}' || echo 0)
                    [ "${N_TCK:-0}" -gt 0 ] && info "${LOB_NAME} × ${BUNDLE} : ${N_TCK} streamlines"
                fi
            done
        done
    fi

    # ------------------------------------------------------------------
    # ÉTAPE 12 : Figures mrview
    #   - Figure 1 : CST (G/D) + AF (G/D) → QC pipeline (vue coronale)
    #   - Figure 2a : tous les tracts cérébelleux + overlay DeepCeres (vue sagittale)
    #   - Figure 2b : une figure par lobule DeepCeres (vue sagittale)
    # Sortie : OUT/figures/  (PNG nommés *0001.png par mrview)
    # ------------------------------------------------------------------
    log "[12/12] Génération des figures mrview"

    if ! command -v mrview &>/dev/null; then
        warn "mrview introuvable — figures ignorées"
    else

    # Couleur par bundle (RGB 0-1)
    bundle_color() {
        case "$1" in
            CST_left)  echo "0.9,0.1,0.1" ;;
            CST_right) echo "0.1,0.1,0.9" ;;
            AF_left)   echo "0.1,0.7,0.1" ;;
            AF_right)  echo "0.9,0.5,0.0" ;;
            ICP_left)  echo "0.8,0.2,0.9" ;;
            ICP_right) echo "0.5,0.0,0.9" ;;
            MCP)       echo "0.0,0.9,0.9" ;;
            SCP_left)  echo "0.9,0.8,0.0" ;;
            SCP_right) echo "0.4,0.9,0.0" ;;
            FPT_left)  echo "1.0,0.5,0.3" ;;
            FPT_right) echo "0.3,0.5,1.0" ;;
            *)         echo "0.7,0.7,0.7" ;;
        esac
    }

    # ── Figure 1 : bundles QC (CST + AF, vue coronale) ────────────────
    FIG1="${OUT_FIGS}/${SUBJECT_ID}_fig1_qc-bundles0001.png"
    if ! skip_if_exists "$FIG1" "figure QC bundles (mrview)"; then
        MRVIEW_ARGS=()
        for BUNDLE in CST_left CST_right AF_left AF_right; do
            TCK="${OUT_BUNDLES}/${SUBJECT_ID}_bundle-${BUNDLE}_space-MNI.tck"
            [ -f "$TCK" ] || continue
            MRVIEW_ARGS+=(
                -tractography.load "$TCK"
                -tractography.colour "$(bundle_color "$BUNDLE")"
                -tractography.slab -1
                -tractography.geometry pseudotubes
                -tractography.thickness 0.2
            )
        done
        mrview "$FA_MNI" \
            -mode 1 -plane 1 \
            -size 1920,1080 -noannotations \
            "${MRVIEW_ARGS[@]}" \
            -capture.folder "$OUT_FIGS" \
            -capture.prefix "${SUBJECT_ID}_fig1_qc-bundles" \
            -capture.grab -exit 2>/dev/null \
            && info "Figure QC bundles : ${FIG1}" \
            || warn "mrview figure 1 échouée (display disponible ?)"
    fi

    # ── Figure 2a : tous les tracts cérébelleux + overlay DeepCeres ───
    FIG2="${OUT_FIGS}/${SUBJECT_ID}_fig2_cerebellum-all0001.png"
    if ! skip_if_exists "$FIG2" "figure cervelet global (mrview)"; then
        MRVIEW_ARGS=()
        IFS=',' read -ra BUNDLE_LIST_FIG <<< "$CEREB_BUNDLES"
        for BUNDLE in "${BUNDLE_LIST_FIG[@]}"; do
            TCK="${OUT_CEREB}/${SUBJECT_ID}_bundle-${BUNDLE}_space-MNI_cerebellar.tck"
            [ -f "$TCK" ] || continue
            MRVIEW_ARGS+=(
                -tractography.load "$TCK"
                -tractography.colour "$(bundle_color "$BUNDLE")"
                -tractography.slab -1
                -tractography.geometry pseudotubes
                -tractography.thickness 0.2
            )
        done
        OVERLAY_ARGS=()
        if [ "$DEEPCERES_OK" = "true" ] && [ -f "$DEPC_STRUCT_MNI" ]; then
            OVERLAY_ARGS=(
                -overlay.load "$DEPC_STRUCT_MNI"
                -overlay.colourmap 3
                -overlay.opacity 0.35
                -overlay.no_threshold_min
            )
        fi
        mrview "$FA_MNI" \
            -mode 1 -plane 0 \
            -size 1920,1080 -noannotations \
            "${OVERLAY_ARGS[@]}" \
            "${MRVIEW_ARGS[@]}" \
            -capture.folder "$OUT_FIGS" \
            -capture.prefix "${SUBJECT_ID}_fig2_cerebellum-all" \
            -capture.grab -exit 2>/dev/null \
            && info "Figure cervelet global : ${FIG2}" \
            || warn "mrview figure 2a échouée"
    fi

    # ── Figure 2b : une figure par lobule DeepCeres ────────────────────
    if [ "$DEEPCERES_OK" = "true" ]; then
        IFS=',' read -ra BUNDLE_LIST_FIG <<< "$CEREB_BUNDLES"
        for IDX in "${!LOBULE_IDXS[@]}"; do
            LOB_NAME="${LOBULE_NAMS[$IDX]}"
            LOB_MASK="${OUT_LOBULES}/${SUBJECT_ID}_desc-deepceres-${LOB_NAME}_mask.nii.gz"
            FIG_LOB="${OUT_FIGS}/${SUBJECT_ID}_fig3_lobule-${LOB_NAME}0001.png"
            [ -f "$LOB_MASK" ] || continue
            if ! skip_if_exists "$FIG_LOB" "figure lobule ${LOB_NAME} (mrview)"; then
                MRVIEW_ARGS=()
                HAS_TCK=false
                for BUNDLE in "${BUNDLE_LIST_FIG[@]}"; do
                    TCK="${OUT_LOBULES}/${SUBJECT_ID}_bundle-${BUNDLE}_desc-deepceres-${LOB_NAME}.tck"
                    [ -f "$TCK" ] || continue
                    N_TCK=$(tckinfo "$TCK" 2>/dev/null | grep ' count' | awk '{print $NF}' || echo 0)
                    [ "${N_TCK:-0}" -gt 0 ] || continue
                    MRVIEW_ARGS+=(
                        -tractography.load "$TCK"
                        -tractography.colour "$(bundle_color "$BUNDLE")"
                        -tractography.slab -1
                        -tractography.geometry pseudotubes
                        -tractography.thickness 0.2
                    )
                    HAS_TCK=true
                done
                [ "$HAS_TCK" = "true" ] || continue
                mrview "$FA_MNI" \
                    -mode 1 -plane 0 \
                    -size 1920,1080 -noannotations \
                    -overlay.load "$LOB_MASK" \
                    -overlay.colourmap 1 \
                    -overlay.opacity 0.5 \
                    -overlay.threshold_min 0.5 \
                    "${MRVIEW_ARGS[@]}" \
                    -capture.folder "$OUT_FIGS" \
                    -capture.prefix "${SUBJECT_ID}_fig3_lobule-${LOB_NAME}" \
                    -capture.grab -exit 2>/dev/null \
                    && info "Figure lobule ${LOB_NAME} : ${FIG_LOB}" \
                    || warn "mrview figure 3 ${LOB_NAME} échouée"
            fi
        done
    fi

    fi  # fin mrview disponible

    log ">>> Sujet ${SUBJECT_ID} terminé — Résultats : ${OUT}"

done

log "Pipeline TractSeg cervelet terminé."
echo ""
echo -e "${BOLD}Résultats :${RESET} ${RESULTS_ROOT}"
