#!/bin/bash
# =============================================================================
# 06_tractseg_cerebellum.sh
# Tractographie bundle-spécifique (TractSeg) centrée sur le cervelet
# Dépendances : TractSeg (installé localement), MRtrix3, FSL
#
# Données d'entrée (issues de 02_mrtrix_pipeline.sh) :
#   results/mrtrix/sub-XX/dwi/
#     sub-XX_desc-msmtNorm_model-CSD_wm.mif   (FOD WM normalisé)
#     sub-XX_model-DTI_param-FA_dti.nii.gz     (FA — pour recalage MNI)
#     sub-XX_space-dwi_desc-brain_mask.nii.gz  (masque cerveau)
#   ~/Data/Socosca/sub-XX/anat/T1.nii.gz       (T1 brut — pour recalage DeepCeres)
#   results/deepceres/sub-XX/
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
#   6. Retour en espace sujet (flirt inverse)
#   7. Filtrage : conserver uniquement les streamlines touchant le cervelet
#      (masque DeepCeres — tous labels > 0 recalé en espace DWI)
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
#   DeepCeres native_structures (tous labels > 0) recalé T1→DWI via flirt 6 dof
#
# Sorties :
#   results/tractseg/sub-XX/
#     peaks/         peaks CSD en espace DWI et MNI
#     registration/  matrices de transformation DWI↔MNI
#     tractseg/      sorties brutes TractSeg (segmentations, TOM)
#     bundles/       tractogrammes .tck par bundle (espace sujet)
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
MRTRIX_RESULTS="${EXP_DIR}/results/mrtrix"
RESULTS_ROOT="${EXP_DIR}/results/tractseg"

SKIP_EXISTING="${SKIP_EXISTING:-true}"
NTHR="${NTHR_DEFAULT}"
SUBJECT_ARG=""

# Bundles cérébelleux à traiter (séparés par des virgules pour TractSeg/Tracking)
CEREB_BUNDLES="ICP_left,ICP_right,MCP,SCP_left,SCP_right,FPT_left,FPT_right"


# Bundles QC classiques (pour vérification qualité du pipeline)
QC_BUNDLES="CST_left,CST_right,AF_left,AF_right"

# Segmentation cérébelleuse DeepCeres
DEEPCERES_RESULTS="${EXP_DIR}/results/deepceres"

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
    # ÉTAPE 6 : Retour en espace sujet (DWI natif)
    # tcktransform attend un champ de déformation NIfTI 4D (pas une matrice .txt).
    # Approche : warpinit crée un champ identité en espace MNI (coordonnées
    # scanner stockées à chaque voxel), puis on applique la transform linéaire
    # MNI→DWI à chaque vecteur stocké → champ de déformation utilisable par tcktransform.
    # ------------------------------------------------------------------
    log "[6/8] Retransformation des streamlines MNI → espace DWI"

    # 1. Composer les transformées inverses ANTs en un champ de déplacement MNI→DWI
    # antsApplyTransforms -o [file,1] génère un champ de déplacement (mm) dans l'espace MNI.
    ANTS_DISP="${OUT_REG}/${SUBJECT_ID}_from-MNI_to-dwi_ants-disp.nii.gz"
    if ! skip_if_exists "$ANTS_DISP" "champ de déplacement ANTs MNI→DWI"; then
        antsApplyTransforms \
            -d 3 \
            -o "[${ANTS_DISP},1]" \
            -r "$FA_MNI" \
            -t "[${ANTS_AFFINE},1]" \
            -t "$ANTS_INV_WARP"
        info "Champ de déplacement ANTs MNI→DWI : ${ANTS_DISP}"
    fi

    # 2. Convertir champ de déplacement ANTs (mm offset) → champ absolu MRtrix
    # MRtrix tcktransform attend : chaque voxel (x_MNI) contient les coordonnées DWI absolues.
    # Formule : x_DWI = x_MNI_world + displacement(x_MNI)
    WARP_FIELD="${OUT_REG}/${SUBJECT_ID}_from-MNI_to-dwi_warp.nii.gz"
    if ! skip_if_exists "$WARP_FIELD" "champ de déformation MNI→DWI (MRtrix)"; then
        python3 - <<PYEOF
import nibabel as nib
import numpy as np

# Champ de déplacement ANTs : chaque voxel en espace MNI stocke le déplacement en mm
disp = nib.load("${ANTS_DISP}")
data = disp.get_fdata()
# ANTs peut produire (x,y,z,1,3) ou (x,y,z,3)
if data.ndim == 5:
    data = data[:, :, :, 0, :]
shape = data.shape[:3]
affine = disp.affine

# Coordonnées monde (mm, RAS) de chaque voxel dans l'espace MNI
i, j, k = np.meshgrid(np.arange(shape[0]), np.arange(shape[1]),
                      np.arange(shape[2]), indexing='ij')
vox = np.stack([i.ravel(), j.ravel(), k.ravel(), np.ones(i.size)], axis=0)  # 4×N
world_mni = (affine @ vox).T[:, :3]  # N×3

# x_DWI = x_MNI_world + déplacement (convention ANTs : déplacement en mm RAS)
abs_coords = world_mni + data.reshape(-1, 3)

out = nib.Nifti1Image(abs_coords.reshape(shape + (3,)).astype(np.float32),
                      affine, disp.header)
nib.save(out, "${WARP_FIELD}")
print(f"  Champ MRtrix MNI→DWI (ANTs SyN) : {out.shape}")
PYEOF
    fi

    IFS=',' read -ra BUNDLE_LIST <<< "$CEREB_BUNDLES"

    for BUNDLE in "${BUNDLE_LIST[@]}"; do
        TCK_MNI="${TS_TRACK_DIR}/${BUNDLE}.tck"
        TCK_DWI="${OUT_BUNDLES}/${SUBJECT_ID}_bundle-${BUNDLE}_space-dwi.tck"

        [ -f "$TCK_MNI" ] || { warn "Tractogramme introuvable : ${TCK_MNI}"; continue; }

        if ! skip_if_exists "$TCK_DWI" "bundle ${BUNDLE} (espace DWI)"; then
            tcktransform "$TCK_MNI" "$WARP_FIELD" "$TCK_DWI" -force
            info "${BUNDLE} → espace DWI : $(tckinfo "$TCK_DWI" | grep ' count' | awk '{print $NF}') streamlines"
        fi
    done

    # ------------------------------------------------------------------
    # ÉTAPE 7 : Masque cérébelleux depuis DeepCeres
    # Recalage atlas DeepCeres (espace T1 natif) → espace DWI (FA)
    # Puis filtrage : conserver les streamlines touchant le masque
    # ------------------------------------------------------------------
    log "[7/8] Filtrage par ROI cérébelleuse (DeepCeres)"

    DEPC_BRAIN_T1="${OUT_REG}/${SUBJECT_ID}_space-T1w_desc-brain_T1w.nii.gz"
    DEPC_STRUCT_DWI="${OUT_CEREB}/${SUBJECT_ID}_space-dwi_desc-deepceres_dseg.nii.gz"
    CEREB_MASK_DWI="${OUT_CEREB}/${SUBJECT_ID}_space-dwi_desc-deepceres-all_mask.nii.gz"

    # 1. Brain-extract le T1 brut avec le masque DeepCeres pour le recalage
    if ! skip_if_exists "$DEPC_BRAIN_T1" "T1 brain-extracted (masque DeepCeres)"; then
        python3 - <<PYEOF
import nibabel as nib, numpy as np
import nibabel.processing as nbp
t1   = nib.load("${T1_ORIG}")
mask = nib.load("${DEPC_MASK_NAT}")
mask_res = nbp.resample_from_to(mask, t1, order=0)
out = (t1.get_fdata() * (mask_res.get_fdata() > 0)).astype(np.float32)
nib.save(nib.Nifti1Image(out, t1.affine, t1.header), "${DEPC_BRAIN_T1}")
print(f"  T1 brain-extracted : {int((out > 0).sum())} voxels non nuls")
PYEOF
        info "T1 brain-extracted : ${DEPC_BRAIN_T1}"
    fi

    # 2. Registration T1→DWI via ANTs rigid (plus robuste que flirt sur macOS ARM)
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

    # 3. Recaler l'atlas DeepCeres en espace DWI (nearest neighbour via ANTs)
    if ! skip_if_exists "$DEPC_STRUCT_DWI" "atlas DeepCeres (espace DWI)"; then
        antsApplyTransforms \
            -d 3 \
            -r "$FA" \
            -i "$DEPC_STRUCT_NAT" \
            -o "$DEPC_STRUCT_DWI" \
            -n NearestNeighbor \
            -t "$ANTS_RIGID_MAT"
        info "Atlas DeepCeres recalé en espace DWI : ${DEPC_STRUCT_DWI}"
    fi

    # 4. Masque binaire = tous labels > 0
    if ! skip_if_exists "$CEREB_MASK_DWI" "masque cérébelleux complet (DeepCeres)"; then
        python3 - <<PYEOF
import nibabel as nib, numpy as np
s = nib.load("${DEPC_STRUCT_DWI}")
mask = (s.get_fdata() > 0).astype(np.uint8)
nib.save(nib.Nifti1Image(mask, s.affine, s.header), "${CEREB_MASK_DWI}")
print(f"  Masque DeepCeres complet : {int(mask.sum())} voxels")
PYEOF
        info "Masque cérébelleux DeepCeres : ${CEREB_MASK_DWI}"
    fi

    # Filtrer chaque tractogramme bundle : garder les streamlines passant par le cervelet
    for BUNDLE in "${BUNDLE_LIST[@]}"; do
        TCK_DWI="${OUT_BUNDLES}/${SUBJECT_ID}_bundle-${BUNDLE}_space-dwi.tck"
        TCK_CEREB="${OUT_CEREB}/${SUBJECT_ID}_bundle-${BUNDLE}_cerebellar.tck"
        TCK_DENSITY="${OUT_CEREB}/${SUBJECT_ID}_bundle-${BUNDLE}_density.nii.gz"

        [ -f "$TCK_DWI" ] || { warn "Tractogramme DWI introuvable pour ${BUNDLE}"; continue; }

        if ! skip_if_exists "$TCK_CEREB" "filtrage cérébelleux ${BUNDLE}"; then
            # Conserver les streamlines dont au moins un point est dans le masque cérébelleux
            tckedit "$TCK_DWI" "$TCK_CEREB" \
                -include "$CEREB_MASK_DWI" \
                -force
            N=$(tckinfo "$TCK_CEREB" 2>/dev/null | grep ' count' | awk '{print $NF}' || echo "?")
            info "${BUNDLE} cérébelleux : ${N} streamlines"
        fi

        # Carte de densité (TDI) pour le bundle cérébelleux filtré
        if ! skip_if_exists "$TCK_DENSITY" "densité ${BUNDLE}"; then
            tckmap "$TCK_CEREB" "$TCK_DENSITY" \
                -template "$FA" \
                -force -quiet
        fi
    done

    # TDI globale : tous les bundles cérébelleux fusionnés en espace DWI
    # Utile pour vérifier visuellement que le recalage est correct (overlay sur FA)
    TCK_ALL_CEREB="${OUT_CEREB}/${SUBJECT_ID}_all-cerebellar.tck"
    TDI_ALL_CEREB="${OUT_CEREB}/${SUBJECT_ID}_tdi-all-cerebellar.nii.gz"

    if ! skip_if_exists "$TCK_ALL_CEREB" "fusion tous bundles cérébelleux"; then
        CEREB_TCKS=()
        for BUNDLE in "${BUNDLE_LIST[@]}"; do
            TCK_CEREB="${OUT_CEREB}/${SUBJECT_ID}_bundle-${BUNDLE}_cerebellar.tck"
            [ -f "$TCK_CEREB" ] && CEREB_TCKS+=("$TCK_CEREB")
        done
        if [ "${#CEREB_TCKS[@]}" -gt 0 ]; then
            tckedit "${CEREB_TCKS[@]}" "$TCK_ALL_CEREB" -force -quiet
            N_ALL=$(tckinfo "$TCK_ALL_CEREB" 2>/dev/null | grep ' count' | awk '{print $NF}' || echo "?")
            info "Fusion cérébelleux : ${N_ALL} streamlines → ${TCK_ALL_CEREB}"
        else
            warn "Aucun bundle cérébelleux disponible pour la fusion"
        fi
    fi

    if ! skip_if_exists "$TDI_ALL_CEREB" "TDI globale cérébelleux"; then
        [ -f "$TCK_ALL_CEREB" ] && \
        tckmap "$TCK_ALL_CEREB" "$TDI_ALL_CEREB" \
            -template "$FA" \
            -force -quiet && \
        info "TDI globale cérébelleux : ${TDI_ALL_CEREB}"
    fi

    # ------------------------------------------------------------------
    # ÉTAPE 8 : Métriques DTI par bundle (tractométrie simple)
    # ------------------------------------------------------------------
    log "[8/8] Métriques DTI par bundle (tractométrie)"

    STATS_TSV="${OUT_STATS}/${SUBJECT_ID}_tractseg_cerebellum_stats.tsv"

    if ! skip_if_exists "$STATS_TSV" "métriques tractométrie"; then
        MD="${IN_DWI}/${SUBJECT_ID}_model-DTI_param-MD_dti.nii.gz"
        AD="${IN_DWI}/${SUBJECT_ID}_model-DTI_param-AD_dti.nii.gz"
        RD="${IN_DWI}/${SUBJECT_ID}_model-DTI_param-RD_dti.nii.gz"

        python3 - <<PYEOF
import nibabel as nib
import numpy as np
import csv, os

subject = "${SUBJECT_ID}"
bundles = [b.strip() for b in "${CEREB_BUNDLES}".split(",")]
out_dir = "${OUT_CEREB}"
stats_dir = "${OUT_STATS}"

metrics = {
    "FA":  "${FA}",
    "MD":  "${MD}",
    "AD":  "${AD}",
    "RD":  "${RD}",
}

rows = []
for bundle in bundles:
    density_file = os.path.join(out_dir, f"{subject}_bundle-{bundle}_density.nii.gz")
    if not os.path.isfile(density_file):
        print(f"  [SKIP] densité introuvable pour {bundle}")
        continue

    density = nib.load(density_file).get_fdata()
    if density.sum() == 0:
        print(f"  [WARN] densité nulle pour {bundle}")
        continue

    # Masque pondéré par densité (streamline count > 0)
    wmask = density > 0
    n_vox = int(wmask.sum())

    row = {"subject": subject, "bundle": bundle, "n_voxels": n_vox}
    for mname, mpath in metrics.items():
        if not os.path.isfile(mpath):
            row[mname + "_mean"] = "NA"
            row[mname + "_std"] = "NA"
            continue
        mdata = nib.load(mpath).get_fdata()
        vals = mdata[wmask]
        vals = vals[np.isfinite(vals)]
        row[mname + "_mean"] = round(float(np.mean(vals)), 6) if len(vals) > 0 else "NA"
        row[mname + "_std"]  = round(float(np.std(vals)), 6)  if len(vals) > 0 else "NA"
    rows.append(row)
    print(f"  {bundle}: {n_vox} voxels, FA={row.get('FA_mean','NA')}")

if rows:
    fieldnames = list(rows[0].keys())
    with open("${STATS_TSV}", "w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=fieldnames, delimiter="\t")
        writer.writeheader()
        writer.writerows(rows)
    print(f"  Statistiques sauvegardées : ${STATS_TSV}")
else:
    print("  [WARN] Aucune statistique calculée")
PYEOF
        info "Métriques DTI par bundle → ${STATS_TSV}"
    fi

    # ------------------------------------------------------------------
    # ÉTAPE 9 : Bundles QC (CST + AF) → espace DWI
    # TractSeg TOM déjà calculés pour tous les bundles à l'étape 4
    # ------------------------------------------------------------------
    log "[9/12] Bundles QC (CST + AF) — tracking + transformation DWI"

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
        TCK_DWI="${OUT_BUNDLES}/${SUBJECT_ID}_bundle-${BUNDLE}_space-dwi.tck"
        [ -f "$TCK_MNI" ] || { warn "Tractogramme QC introuvable : ${TCK_MNI}"; continue; }
        if ! skip_if_exists "$TCK_DWI" "bundle QC ${BUNDLE} (espace DWI)"; then
            tcktransform "$TCK_MNI" "$WARP_FIELD" "$TCK_DWI" -force
            info "${BUNDLE} → espace DWI : $(tckinfo "$TCK_DWI" | grep ' count' | awk '{print $NF}') streamlines"
        fi
    done

    # ------------------------------------------------------------------
    # ÉTAPE 10 : Atlas DeepCeres par lobule (déjà recalé en espace DWI à l'étape 7)
    # DEPC_STRUCT_DWI, MAT_T12DWI et CEREB_MASK_DWI sont définis à l'étape 7.
    # ------------------------------------------------------------------
    log "[10/12] Atlas DeepCeres lobulaire (espace DWI)"

    # Tableaux parallèles : labels D (1-12) et noms des lobules
    # Labels G = label D + 100 ; labels 13 / 113 = WM (non utilisé pour figures)
    LOBULE_IDXS=(1 2 3 4 5 6 7 8 9 10 11 12)
    LOBULE_NAMS=("LobI-II" "LobIII" "LobIV" "LobV" "LobVI" "CrusI" "CrusII" "LobVIIB" "LobVIIIA" "LobVIIIB" "LobIX" "LobX")

    DEEPCERES_OK=false
    OUT_LOBULES="${OUT_CEREB}/per_lobule"

    if [ -f "$DEPC_STRUCT_DWI" ]; then
        DEEPCERES_OK=true
    else
        warn "${SUBJECT_ID} : DEPC_STRUCT_DWI absent (${DEPC_STRUCT_DWI}) — étapes 10-12 ignorées"
    fi

    # ------------------------------------------------------------------
    # ÉTAPE 11 : Filtrage des tracts par lobule cérébelleux DeepCeres
    # Pour chaque lobule bilatéral : masque binaire DWI → tckedit --include
    # ------------------------------------------------------------------
    if [ "$DEEPCERES_OK" = "true" ]; then

        # TDI globale basée sur le masque cérébelleux complet DeepCeres
        # (CEREB_MASK_DWI = tous labels > 0, calculé à l'étape 7)
        TCK_DEPC_ALL="${OUT_CEREB}/${SUBJECT_ID}_all-cerebellar-deepceres.tck"
        TDI_DEPC_ALL="${OUT_CEREB}/${SUBJECT_ID}_tdi-deepceres-cerebellum.nii.gz"

        if ! skip_if_exists "$TDI_DEPC_ALL" "TDI cérébelleux complet DeepCeres"; then
            if [ -f "$TCK_ALL_CEREB" ] && [ -f "$CEREB_MASK_DWI" ]; then
                tckedit "$TCK_ALL_CEREB" "$TCK_DEPC_ALL" \
                    -include "$CEREB_MASK_DWI" -force -quiet
                tckmap "$TCK_DEPC_ALL" "$TDI_DEPC_ALL" \
                    -template "$FA" -force -quiet
                N_DEPC=$(tckinfo "$TCK_DEPC_ALL" 2>/dev/null | grep ' count' | awk '{print $NF}' || echo "?")
                info "TDI DeepCeres cervelet : ${N_DEPC} streamlines → ${TDI_DEPC_ALL}"
            else
                warn "TDI DeepCeres ignorée : ${TCK_ALL_CEREB} ou ${CEREB_MASK_DWI} manquant"
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
s = nib.load("${DEPC_STRUCT_DWI}")
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
                TCK_IN="${OUT_BUNDLES}/${SUBJECT_ID}_bundle-${BUNDLE}_space-dwi.tck"
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
            TCK="${OUT_BUNDLES}/${SUBJECT_ID}_bundle-${BUNDLE}_space-dwi.tck"
            [ -f "$TCK" ] || continue
            MRVIEW_ARGS+=(
                -tractography.load "$TCK"
                -tractography.colour "$(bundle_color "$BUNDLE")"
                -tractography.slab -1
                -tractography.geometry pseudotubes
                -tractography.thickness 0.2
            )
        done
        mrview "$FA" \
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
            TCK="${OUT_CEREB}/${SUBJECT_ID}_bundle-${BUNDLE}_cerebellar.tck"
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
        if [ "$DEEPCERES_OK" = "true" ] && [ -f "$DEPC_STRUCT_DWI" ]; then
            OVERLAY_ARGS=(
                -overlay.load "$DEPC_STRUCT_DWI"
                -overlay.colourmap 3
                -overlay.opacity 0.35
                -overlay.no_threshold_min
            )
        fi
        mrview "$FA" \
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
                mrview "$FA" \
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
