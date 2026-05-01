#!/bin/bash
# =============================================================================
# 07_scilpy_cerebellum.sh
# Visualisation scilpy des tractogrammes connectés au cervelet (DeepCeres)
#
# Alternative à TractSeg : travaille entièrement en espace DWI natif.
# Aucune transformation inter-espace → pas de risque de désalignement.
#
# Dépendances :
#   - 02_mrtrix_pipeline.sh  → tractogramme SIFT2 whole-brain (.tck)
#   - 06_tractseg_cerebellum.sh (étape 10) → DeepCeres atlas en espace DWI
#   - scilpy 2.x (installé dans l'env conda « scilpy » — Python 3.12)
#   - MRtrix3 (mrconvert pour conversion .mif→.nii.gz si besoin)
#   - FSL, conda/miniforge3
#
# Données d'entrée :
#   results/mrtrix/sub-XX/tractography/
#     sub-XX_desc-iFOD2sift2_200k.tck         (tractogramme whole-brain)
#   results/mrtrix/sub-XX/dwi/
#     sub-XX_model-DTI_param-FA_dti.nii.gz    (carte FA — référence géométrique)
#     sub-XX_model-DTI_param-MD_dti.nii.gz
#     sub-XX_model-DTI_param-AD_dti.nii.gz
#     sub-XX_model-DTI_param-RD_dti.nii.gz
#   results/tractseg/sub-XX/cerebellum/
#     sub-XX_space-dwi_desc-deepceres_dseg.nii.gz   (atlas DeepCeres, labels 1-13/101-113)
#     sub-XX_space-dwi_desc-deepceres-all_mask.nii.gz (masque binaire cérébelleux complet)
#
# Pipeline :
#   0. Vérification / installation scilpy dans l'env conda
#   1. Conversion tck → trk (.tck + référence FA → .trk natif scilpy)
#   2. Filtrage cérébelleux global (drawn_roi any include) → cereb_all.trk
#   3. Filtrage par lobule (atlas_roi either_end include) → per_lobule/*.trk
#   4. Matrice de connectivité intra-cérébelleux (segment_connections_from_labels)
#   5. Cartes de densité de streamlines (compute_density_map) — global + par lobule
#   6. Tractométrie par lobule (bundle_mean_std → JSON/TSV)
#   7. Figures (mrview + scil_viz_connectivity)
#
# Labels DeepCeres :
#   1-12   = lobules hémisphère droit (LobI-II … LobX)
#   101-112 = lobules hémisphère gauche
#   13, 113 = substance blanche (exclus des lobules)
#
# Usage :
#   bash scripts/07_scilpy_cerebellum.sh [--sub sub-01] [--force] [--help]
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
EXP_DIR="${HOME}/Exp/socosca"
MRTRIX_RESULTS="${EXP_DIR}/results/mrtrix"
TRACTSEG_RESULTS="${EXP_DIR}/results/tractseg"
RESULTS_ROOT="${EXP_DIR}/results/scilpy"
CONDA_PREFIX="${HOME}/miniforge3"

SKIP_EXISTING="${SKIP_EXISTING:-true}"
SUBJECT_ARG=""

# Labels DeepCeres
LOBULE_IDXS=(1 2 3 4 5 6 7 8 9 10 11 12)
LOBULE_NAMS=("LobI-II" "LobIII" "LobIV" "LobV" "LobVI" "CrusI" "CrusII" "LobVIIB" "LobVIIIA" "LobVIIIB" "LobIX" "LobX")

# ---------------------------------------------------------------------------
# Parsing des arguments
# ---------------------------------------------------------------------------
usage() {
    cat <<EOF
Usage: $(basename "$0") [--sub <id>] [--force] [--help]

  --sub       traiter un seul sujet (ex: sub-01)
  --force     relancer tous les calculs même si les résultats existent
  --help      afficher cette aide
EOF
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --sub)    SUBJECT_ARG="$2"; shift 2 ;;
        --force)  SKIP_EXISTING="false"; shift ;;
        --help|-h) usage ;;
        *) echo "Argument inconnu : $1"; exit 1 ;;
    esac
done

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
    if [ "${SKIP_EXISTING}" = "true" ] && [ -d "$dir" ] && [ "$(ls -A "$dir" 2>/dev/null | wc -l)" -gt 0 ]; then
        echo -e "  ${YELLOW}[SKIP]${RESET} ${label}"
        return 0
    fi
    return 1
}

# ---------------------------------------------------------------------------
# ÉTAPE 0 : Vérification / installation scilpy
# ---------------------------------------------------------------------------
log "[0] Vérification de l'environnement scilpy"

SCILPY_ENV="${CONDA_PREFIX}/envs/scilpy"
SCIL_BIN="${SCILPY_ENV}/bin"

if [ ! -d "${SCILPY_ENV}" ]; then
    info "Création de l'environnement conda scilpy (Python 3.12)…"
    "${CONDA_PREFIX}/bin/conda" create -n scilpy python=3.12 -y
    info "Installation de scilpy…"
    "${SCIL_BIN}/pip" install scilpy
elif [ ! -f "${SCIL_BIN}/scil_tractogram_filter_by_roi" ]; then
    info "scilpy non installé dans l'env — installation…"
    "${SCIL_BIN}/pip" install scilpy
else
    SCILPY_VER=$("${SCIL_BIN}/python3" -c "import scilpy; print(scilpy.__version__)" 2>/dev/null || echo "?")
    info "scilpy ${SCILPY_VER} détecté dans ${SCILPY_ENV}"
fi

# Raccourci : ${SCIL} scil_xxx = appel dans l'env scilpy sans activation globale
SCIL_PYTHON="${SCIL_BIN}/python3"

# Wrapper pour appeler un script scilpy (évite l'activation conda dans le shell)
run_scil() {
    local cmd="$1"; shift
    "${SCIL_BIN}/${cmd}" "$@"
}

# ---------------------------------------------------------------------------
# Boucle sujets
# ---------------------------------------------------------------------------
if [ -n "${SUBJECT_ARG}" ]; then
    SUBJECTS=("${SUBJECT_ARG}")
else
    SUBJECTS=()
    while IFS= read -r _s; do SUBJECTS+=("$_s"); done < <(
        ls -d "${MRTRIX_RESULTS}"/sub-*/  2>/dev/null | xargs -I{} basename {})
fi

[ ${#SUBJECTS[@]} -eq 0 ] && die "Aucun sujet trouvé dans ${MRTRIX_RESULTS}"

for SUBJECT_ID in "${SUBJECTS[@]}"; do

    log "======= SUJET : ${SUBJECT_ID} ======="

    # -----------------------------------------------------------------------
    # Chemins d'entrée
    # -----------------------------------------------------------------------
    IN_DWI="${MRTRIX_RESULTS}/${SUBJECT_ID}/dwi"
    IN_TRACT="${MRTRIX_RESULTS}/${SUBJECT_ID}/tractography"
    IN_CEREB="${TRACTSEG_RESULTS}/${SUBJECT_ID}/cerebellum"

    FA="${IN_DWI}/${SUBJECT_ID}_model-DTI_param-FA_dti.nii.gz"
    MD="${IN_DWI}/${SUBJECT_ID}_model-DTI_param-MD_dti.nii.gz"
    AD="${IN_DWI}/${SUBJECT_ID}_model-DTI_param-AD_dti.nii.gz"
    RD="${IN_DWI}/${SUBJECT_ID}_model-DTI_param-RD_dti.nii.gz"
    TCK_WB="${IN_TRACT}/${SUBJECT_ID}_desc-iFOD2sift2_200k.tck"
    DEPC_ATLAS="${IN_CEREB}/${SUBJECT_ID}_space-dwi_desc-deepceres_dseg.nii.gz"
    DEPC_MASK="${IN_CEREB}/${SUBJECT_ID}_space-dwi_desc-deepceres-all_mask.nii.gz"

    # Vérifications préalables
    for f in "$FA" "$TCK_WB" "$DEPC_ATLAS" "$DEPC_MASK"; do
        [ -f "$f" ] || die "Fichier manquant : ${f}\n  → Lancer 02_mrtrix_pipeline.sh et 06_tractseg_cerebellum.sh d'abord"
    done

    # -----------------------------------------------------------------------
    # Chemins de sortie
    # -----------------------------------------------------------------------
    OUT_DIR="${RESULTS_ROOT}/${SUBJECT_ID}"
    OUT_LOBULES="${OUT_DIR}/per_lobule"
    OUT_DENSITY="${OUT_DIR}/density"
    OUT_STATS="${OUT_DIR}/stats"
    OUT_CONN="${OUT_DIR}/connectivity"
    OUT_FIGS="${OUT_DIR}/figures"

    mkdir -p "${OUT_DIR}" "${OUT_LOBULES}" "${OUT_DENSITY}" \
             "${OUT_STATS}" "${OUT_CONN}" "${OUT_FIGS}"

    # -----------------------------------------------------------------------
    # PRÉ-ÉTAPE : Référence isotrope commune (scilpy connectivité = isotrope obligatoire)
    # Tous les .trk et l'atlas partagent cette même référence.
    # -----------------------------------------------------------------------
    VOX_ISO=$(
        "${SCIL_PYTHON}" -c "
import nibabel as nib, numpy as np
z = nib.load('${FA}').header.get_zooms()[:3]
print(f'{min(z):.4f}')
" 2>/dev/null || echo "1.875")

    FA_ISO="${OUT_DIR}/${SUBJECT_ID}_model-DTI_param-FA_iso.nii.gz"
    if ! skip_if_exists "$FA_ISO" "FA isotrope référence"; then
        run_scil scil_volume_resample \
            "$FA" "$FA_ISO" \
            --voxel_size "$VOX_ISO" --interp lin -f
        info "FA isotrope (${VOX_ISO} mm) : ${FA_ISO}"
    fi

    DEPC_ATLAS_ISO="${OUT_DIR}/${SUBJECT_ID}_space-dwi_desc-deepceres_dseg_iso.nii.gz"
    if ! skip_if_exists "$DEPC_ATLAS_ISO" "atlas DeepCeres isotrope"; then
        mrgrid "$DEPC_ATLAS" regrid \
            -template "$FA_ISO" \
            -interp nearest \
            - -force -quiet | \
        mrconvert - "$DEPC_ATLAS_ISO" -datatype uint16 -force -quiet
        info "Atlas DeepCeres iso : ${DEPC_ATLAS_ISO}"
    fi

    DEPC_MASK_ISO="${OUT_DIR}/${SUBJECT_ID}_space-dwi_desc-deepceres-all_mask_iso.nii.gz"
    if ! skip_if_exists "$DEPC_MASK_ISO" "masque DeepCeres isotrope"; then
        mrgrid "$DEPC_MASK" regrid \
            -template "$FA_ISO" \
            -interp nearest \
            - -force -quiet | \
        mrconvert - "$DEPC_MASK_ISO" -datatype uint8 -force -quiet
        info "Masque DeepCeres iso : ${DEPC_MASK_ISO}"
    fi

    # -----------------------------------------------------------------------
    # ÉTAPE 1 : Conversion tck → trk (référencé sur FA_ISO)
    # -----------------------------------------------------------------------
    log "[1/7] Conversion tractogramme whole-brain tck → trk"

    TRK_WB="${OUT_DIR}/${SUBJECT_ID}_desc-iFOD2sift2_200k.trk"

    if ! skip_if_exists "$TRK_WB" "tractogramme whole-brain .trk"; then
        run_scil scil_tractogram_convert \
            "$TCK_WB" "$TRK_WB" \
            --reference "$FA_ISO" -f
        N_WB=$(run_scil scil_tractogram_count_streamlines "$TRK_WB" 2>/dev/null \
            | "${SCIL_PYTHON}" -c "import sys,json; d=json.load(sys.stdin); print(list(d.values())[0].get('nb_streamlines','?'))" 2>/dev/null || echo "?")
        info "Tractogramme whole-brain : ${N_WB} streamlines → ${TRK_WB}"
    fi

    # -----------------------------------------------------------------------
    # ÉTAPE 2 : Filtrage cérébelleux global
    # « any include » : toute streamline touchant le masque DeepCeres
    # -----------------------------------------------------------------------
    log "[2/7] Filtrage cérébelleux global (any contact avec DeepCeres)"

    TRK_CEREB="${OUT_DIR}/${SUBJECT_ID}_desc-cerebellar-deepceres.trk"

    if ! skip_if_exists "$TRK_CEREB" "tractogramme cérébelleux global"; then
        run_scil scil_tractogram_filter_by_roi \
            "$TRK_WB" "$TRK_CEREB" \
            --drawn_roi "$DEPC_MASK_ISO" any include \
            --display_counts -f
        N_CEREB=$(run_scil scil_tractogram_count_streamlines "$TRK_CEREB" 2>/dev/null \
            | "${SCIL_PYTHON}" -c "import sys,json; d=json.load(sys.stdin); print(list(d.values())[0].get('nb_streamlines','?'))" 2>/dev/null || echo "?")
        info "Tractogramme cérébelleux : ${N_CEREB} streamlines → ${TRK_CEREB}"
    fi

    # -----------------------------------------------------------------------
    # ÉTAPE 3 : Filtrage par lobule DeepCeres
    # « either_end include » : au moins une extrémité dans le lobule
    # → montre les projections entrantes/sortantes de chaque lobule
    # -----------------------------------------------------------------------
    log "[3/7] Filtrage par lobule DeepCeres (either_end include)"

    for IDX in "${!LOBULE_IDXS[@]}"; do
        LABEL_R="${LOBULE_IDXS[$IDX]}"
        LABEL_L=$((LABEL_R + 100))
        LOB_NAME="${LOBULE_NAMS[$IDX]}"
        TRK_LOB="${OUT_LOBULES}/${SUBJECT_ID}_lobule-${LOB_NAME}.trk"

        if ! skip_if_exists "$TRK_LOB" "lobule ${LOB_NAME}"; then
            run_scil scil_tractogram_filter_by_roi \
                "$TRK_WB" "$TRK_LOB" \
                --atlas_roi "$DEPC_ATLAS_ISO" "${LABEL_R} ${LABEL_L}" either_end include \
                --no_empty -f
            if [ -f "$TRK_LOB" ]; then
                N=$(run_scil scil_tractogram_count_streamlines "$TRK_LOB" 2>/dev/null \
                    | "${SCIL_PYTHON}" -c "import sys,json; d=json.load(sys.stdin); print(list(d.values())[0].get('nb_streamlines','?'))" 2>/dev/null || echo "?")
                info "${LOB_NAME} (labels ${LABEL_R}+${LABEL_L}) : ${N} streamlines"
            else
                warn "${LOB_NAME} : aucune streamline avec endpoint dans ce lobule"
            fi
        fi
    done

    # -----------------------------------------------------------------------
    # ÉTAPE 4 : Matrice de connectivité intra-cérébelleux
    # Segmente le tractogramme cérébelleux en paires de lobules connectés.
    # Produit un fichier HDF5 et une matrice 24×24 (12 lobules × 2 hémisphères).
    # NOTE : scilpy exige des voxels isotropes et des headers compatibles.
    # Atlas + masques rééchantillonnés sur FA_ISO en pré-étape.
    # -----------------------------------------------------------------------
    log "[4/7] Matrice de connectivité intra-cérébelleux"

    CONN_H5="${OUT_CONN}/${SUBJECT_ID}_cereb-connections.h5"
    CONN_LABELS="${OUT_CONN}/${SUBJECT_ID}_cereb-labels.txt"
    CONN_FINAL_DIR="${OUT_CONN}/bundles"

    if ! skip_if_exists "$CONN_H5" "connectivité intra-cérébelleux HDF5"; then
        mkdir -p "$CONN_FINAL_DIR"
        run_scil scil_tractogram_segment_connections_from_labels \
            "$TRK_CEREB" "$DEPC_ATLAS_ISO" "$CONN_H5" \
            --out_labels_list "$CONN_LABELS" \
            --out_dir         "$CONN_FINAL_DIR" \
            --save_final \
            --no_remove_outliers \
            -v INFO -f
        info "Connectivité HDF5 : ${CONN_H5}"
        info "Labels : ${CONN_LABELS}"
    fi

    # Matrice de connectivité (comptage streamlines)
    CONN_MATRIX="${OUT_CONN}/${SUBJECT_ID}_cereb-connectivity-sc.npy"

    if [ -f "$CONN_H5" ] && ! skip_if_exists "$CONN_MATRIX" "matrice connectivité streamline count"; then
        run_scil scil_connectivity_compute_matrices \
            "$CONN_H5" "$DEPC_ATLAS_ISO" \
            --streamline_count "$CONN_MATRIX" \
            -f
        info "Matrice connectivité (SC) : ${CONN_MATRIX}"
    fi

    # -----------------------------------------------------------------------
    # ÉTAPE 5 : Cartes de densité (TDI)
    # -----------------------------------------------------------------------
    log "[5/7] Cartes de densité de streamlines"

    # Densité globale cérébelleux
    TDI_CEREB="${OUT_DENSITY}/${SUBJECT_ID}_tdi-cerebellar-deepceres.nii.gz"

    if ! skip_if_exists "$TDI_CEREB" "TDI cérébelleux global"; then
        run_scil scil_tractogram_compute_density_map \
            "$TRK_CEREB" "$TDI_CEREB" \
            -f
        info "TDI cérébelleux : ${TDI_CEREB}"
    fi

    # Densité par lobule
    for IDX in "${!LOBULE_IDXS[@]}"; do
        LOB_NAME="${LOBULE_NAMS[$IDX]}"
        TRK_LOB="${OUT_LOBULES}/${SUBJECT_ID}_lobule-${LOB_NAME}.trk"
        TDI_LOB="${OUT_DENSITY}/${SUBJECT_ID}_tdi-lobule-${LOB_NAME}.nii.gz"

        [ ! -f "$TRK_LOB" ] && continue
        if ! skip_if_exists "$TDI_LOB" "TDI lobule ${LOB_NAME}"; then
            run_scil scil_tractogram_compute_density_map \
                "$TRK_LOB" "$TDI_LOB" \
                -f
        fi
    done

    # -----------------------------------------------------------------------
    # ÉTAPE 6 : Tractométrie par lobule (FA, MD, AD, RD)
    # -----------------------------------------------------------------------
    log "[6/7] Tractométrie DTI par lobule"

    STATS_JSON="${OUT_STATS}/${SUBJECT_ID}_scilpy-lobule-stats.json"

    if ! skip_if_exists "$STATS_JSON" "stats tractométrie par lobule"; then
        # Sérialiser la liste bash → JSON pour Python
        LOB_JSON_LIST="[$(printf '"%s",' "${LOBULE_NAMS[@]}" | sed 's/,$//')]"
        "${SCIL_PYTHON}" - <<PYEOF
import json, os, subprocess, sys

stats = {}
lob_list = json.loads("""${LOB_JSON_LIST}""")
metrics = {"FA": "${FA}", "MD": "${MD}", "AD": "${AD}", "RD": "${RD}"}
scil_bin = "${SCIL_BIN}"

for lob_name in lob_list:
    trk = f"${OUT_LOBULES}/${SUBJECT_ID}_lobule-{lob_name}.trk"
    if not os.path.isfile(trk):
        continue
    stats[lob_name] = {}
    for mname, mpath in metrics.items():
        if not os.path.isfile(mpath):
            continue
        try:
            result = subprocess.run(
                [f"{scil_bin}/scil_bundle_mean_std",
                 trk, mpath, "--density_weighting"],
                capture_output=True, text=True
            )
            # scil_bundle_mean_std renvoie du JSON
            if result.returncode == 0 and result.stdout.strip():
                data = json.loads(result.stdout)
                # Le format est { "filename": { metric: { mean, std } } }
                for v in data.values():
                    if mname in v:
                        stats[lob_name][mname] = v[mname]
        except Exception as e:
            print(f"  [WARN] {lob_name}/{mname}: {e}", file=sys.stderr)

with open("${STATS_JSON}", "w") as f:
    json.dump(stats, f, indent=2)
print(f"Stats JSON écrit : ${STATS_JSON}")
PYEOF
        info "Tractométrie : ${STATS_JSON}"
    fi

    # -----------------------------------------------------------------------
    # ÉTAPE 7 : Figures
    # -----------------------------------------------------------------------
    log "[7/7] Génération des figures"

    # --- Fig 1 : TDI cérébelleux global sur FA (3 plans) ---
    FIG_TDI="${OUT_FIGS}/${SUBJECT_ID}_fig01_tdi-cerebellar.png"

    if ! skip_if_exists "$FIG_TDI" "figure TDI cérébelleux"; then
        if [ -f "$TDI_CEREB" ]; then
            "${SCIL_PYTHON}" - <<PYEOF
import nibabel as nib
import numpy as np
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
from scipy import ndimage

FA_PATH  = "${FA_ISO}"
TDI_PATH = "${TDI_CEREB}"
OUT_PATH = "${FIG_TDI}"
SUBJECT  = "${SUBJECT_ID}"

# Charger et réorienter en RAS+ canonique
fa_img  = nib.as_closest_canonical(nib.load(FA_PATH))
tdi_img = nib.as_closest_canonical(nib.load(TDI_PATH))
fa  = fa_img.get_fdata(dtype=np.float32)
tdi = tdi_img.get_fdata(dtype=np.float32)

# Fenêtrage FA : percentile 2-98 sur voxels non-nuls
fa_nz = fa[fa > 0.01]
fa_lo, fa_hi = (np.percentile(fa_nz, [2, 98]) if len(fa_nz) else [0, 1])
fa_disp = np.clip((fa - fa_lo) / max(fa_hi - fa_lo, 1e-8), 0, 1)

# Fenêtrage TDI : 0 → 95e percentile des voxels non-nuls
tdi_nz = tdi[tdi > 0]
if len(tdi_nz) > 0:
    tdi_hi = np.percentile(tdi_nz, 95)
    tdi_disp = np.where(tdi > 0, np.clip(tdi / max(tdi_hi, 1e-8), 0, 1), 0.0)
else:
    tdi_disp = np.zeros_like(tdi)

# Centre de masse pour la sélection des coupes
cm = ndimage.center_of_mass(tdi > 0)
ci = [int(np.clip(round(c), 0, s - 1)) for c, s in zip(cm, tdi.shape)]

# ── extraction de coupes (RAS+ : axe0=R, axe1=A, axe2=S) ─────────────────
def axial(vol, idx):
    return np.flipud(vol[:, :, idx].T)      # (A, R) → supérieur en haut

def sagittal(vol, idx):
    return np.flipud(vol[idx, :, :].T)      # (S, A) → sup en haut

def coronal(vol, idx):
    return np.flipud(vol[:, idx, :].T)      # (S, R) → sup en haut

# ── fusion FA gris + TDI hot avec alpha adaptatif ─────────────────────────
hot  = plt.colormaps['hot']
gray = plt.colormaps['gray']

def blend(fa_sl, tdi_sl, opacity=0.82):
    fa_rgb   = gray(fa_sl)[..., :3]
    tdi_rgb  = hot(tdi_sl)[..., :3]
    alpha    = np.where(tdi_sl > 0.02,
                        np.clip(tdi_sl * 1.4 + 0.2, 0.40, opacity), 0.0)
    return np.clip(fa_rgb * (1.0 - alpha[..., None])
                   + tdi_rgb * alpha[..., None], 0, 1)

panels = [
    ("Axial",    blend(axial(fa_disp, ci[2]),    axial(tdi_disp, ci[2]))),
    ("Sagittal", blend(sagittal(fa_disp, ci[0]), sagittal(tdi_disp, ci[0]))),
    ("Coronal",  blend(coronal(fa_disp, ci[1]),  coronal(tdi_disp, ci[1]))),
]

BG = '#0d0d0d'
fig, axes = plt.subplots(1, 3, figsize=(15, 5), facecolor=BG,
                         gridspec_kw={'wspace': 0.03})
for ax, (label, img) in zip(axes, panels):
    ax.imshow(img, aspect='equal', interpolation='bilinear', origin='upper')
    ax.set_title(label, color='white', fontsize=11,
                 fontfamily='DejaVu Sans', pad=5)
    ax.set_facecolor(BG)
    ax.axis('off')

fig.text(0.5, 0.97,
         f"{SUBJECT} — TDI cérébelleux (DeepCeres, hot)",
         ha='center', va='top', color='white',
         fontsize=12, fontfamily='DejaVu Sans')
plt.savefig(OUT_PATH, dpi=150, bbox_inches='tight',
            facecolor=BG, edgecolor='none')
print(f"Fig TDI : {OUT_PATH}")
PYEOF
            [ -f "$FIG_TDI" ] && info "Figure TDI : ${FIG_TDI}" || warn "Fig01 TDI échouée"
        fi
    fi

    # --- Fig 2 : Matrice de connectivité cérébelleux ---
    FIG_CONN="${OUT_FIGS}/${SUBJECT_ID}_fig02_connectivity.png"

    if [ -f "$CONN_MATRIX" ] && ! skip_if_exists "$FIG_CONN" "figure matrice connectivité"; then
        # Générer un LUT simplifié pour DeepCeres (labels 1-12 droits + 101-112 gauches)
        LUT_FILE="${OUT_CONN}/${SUBJECT_ID}_deepceres_lut.json"
        "${SCIL_PYTHON}" - <<PYEOF
import json

lobule_nams = ["LobI-II","LobIII","LobIV","LobV","LobVI",
               "CrusI","CrusII","LobVIIB","LobVIIIA","LobVIIIB","LobIX","LobX"]
lut = {}
for i, name in enumerate(lobule_nams, start=1):
    lut[str(i)]       = f"{name}_R"
    lut[str(i + 100)] = f"{name}_L"
lut["13"]  = "WM_R"
lut["113"] = "WM_L"
with open("${LUT_FILE}", "w") as f:
    json.dump(lut, f, indent=2)
PYEOF
        run_scil scil_viz_connectivity \
            "$CONN_MATRIX" "$FIG_CONN" \
            --labels_list "$CONN_LABELS" \
            --display_legend \
            --name_axis \
            -f 2>/dev/null || \
        warn "scil_viz_connectivity non disponible ou échec — vérifier installation fury"
        [ -f "$FIG_CONN" ] && info "Figure connectivité : ${FIG_CONN}"
    fi

    # --- Fig 3 : Tractogramme cérébelleux global sur FA (mrview) ---
    FIG_TRACT="${OUT_FIGS}/${SUBJECT_ID}_fig03_cereb-tractogram.png"

    if ! skip_if_exists "$FIG_TRACT" "figure tractogramme cérébelleux"; then
        if [ -f "$TRK_CEREB" ]; then
            # Convertir TRK → TCK (mrview utilise le format MRtrix)
            TMP_TCK="${OUT_FIGS}/${SUBJECT_ID}_tmp_cereb.tck"
            run_scil scil_tractogram_convert \
                "$TRK_CEREB" "$TMP_TCK" \
                --reference "$FA_ISO" -f 2>/dev/null

            # Centre de masse de l'atlas en coordonnées scanner (mm)
            CM_ATLAS=$(
                "${SCIL_PYTHON}" -c "
import nibabel as nib, numpy as np
from scipy import ndimage
img = nib.load('${DEPC_ATLAS_ISO}')
data = img.get_fdata()
cm_vox = np.array(ndimage.center_of_mass(data > 0))
cm_mm = (img.affine @ np.append(cm_vox, 1))[:3]
print(f'{cm_mm[0]:.2f},{cm_mm[1]:.2f},{cm_mm[2]:.2f}')
" 2>/dev/null || echo "0,0,0")

            mrview "$FA_ISO" \
                -tractography.load "$TMP_TCK" \
                -tractography.opacity 0.55 \
                -tractography.geometry pseudotubes \
                -tractography.thickness 0.3 \
                -tractography.slab -1 \
                -overlay.load "$DEPC_ATLAS_ISO" \
                -overlay.colourmap 12 \
                -overlay.opacity 0.25 \
                -overlay.interpolation 0 \
                -mode 1 -noannotations \
                -target "$CM_ATLAS" \
                -size 700,700 \
                -plane 2 \
                -capture.folder "${OUT_FIGS}/" \
                -capture.prefix "${SUBJECT_ID}_tmp_tract_ax" \
                -capture.grab \
                -plane 0 \
                -capture.prefix "${SUBJECT_ID}_tmp_tract_sag" \
                -capture.grab \
                -plane 1 \
                -capture.prefix "${SUBJECT_ID}_tmp_tract_cor" \
                -capture.grab \
                -exit 2>/dev/null
            rm -f "$TMP_TCK"

            "${SCIL_PYTHON}" - <<PYEOF
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
import matplotlib.image as mpimg
import numpy as np, os

def autocrop(img, thr=0.03):
    gray = img.mean(axis=2) if img.ndim == 3 else img
    rows = np.any(gray > thr, axis=1)
    cols = np.any(gray > thr, axis=0)
    if not rows.any() or not cols.any():
        return img
    r0, r1 = np.where(rows)[0][[0, -1]]
    c0, c1 = np.where(cols)[0][[0, -1]]
    return img[r0:r1+1, c0:c1+1]

panels = [
    ("Axial",    "${OUT_FIGS}/${SUBJECT_ID}_tmp_tract_ax0000.png"),
    ("Sagittal", "${OUT_FIGS}/${SUBJECT_ID}_tmp_tract_sag0000.png"),
    ("Coronal",  "${OUT_FIGS}/${SUBJECT_ID}_tmp_tract_cor0000.png"),
]

BG = '#0d0d0d'
fig, axes = plt.subplots(1, 3, figsize=(13, 5),
                         facecolor=BG,
                         gridspec_kw={'wspace': 0.03})
for ax, (label, path) in zip(axes, panels):
    if not os.path.exists(path):
        ax.set_facecolor(BG); ax.axis('off'); continue
    ax.imshow(autocrop(mpimg.imread(path)), interpolation='lanczos')
    ax.set_title(label, color='white', fontsize=11,
                 fontfamily='DejaVu Sans', pad=5)
    ax.axis('off')

fig.text(0.5, 0.97,
         "${SUBJECT_ID} — Tractogramme cérébelleux (DeepCeres, direction RGB)",
         ha='center', va='top', color='white',
         fontsize=12, fontfamily='DejaVu Sans')
plt.savefig("${FIG_TRACT}", dpi=150, bbox_inches='tight',
            facecolor=BG, edgecolor='none')
print("Fig tractogramme : ${FIG_TRACT}")
PYEOF
            rm -f "${OUT_FIGS}/${SUBJECT_ID}_tmp_tract_"*.png
            [ -f "$FIG_TRACT" ] && info "Figure tractogramme : ${FIG_TRACT}" || warn "Fig03 tractogramme échouée"
        fi
    fi

    log "SUJET ${SUBJECT_ID} terminé → ${OUT_DIR}"

done

echo -e "\n${BOLD}Pipeline scilpy cervelet terminé.${RESET}"
