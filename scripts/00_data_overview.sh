#!/bin/bash
# =============================================================================
# 00_data_overview.sh
# Vue d'ensemble des données IRM du projet Socosca
#
# Pour chaque sujet :
#   - Données anatomiques : dimensions, voxel size, type de séquence
#   - Données DWI         : dimensions, shells (b-values), volumes
#   - Autres séquences    : type (fMRI, T1 3D, ...)
#
# Usage : bash scripts/00_data_overview.sh
# =============================================================================

set -euo pipefail

DATA_DIR="${HOME}/Data/Socosca"
NTHR=4

# Couleurs pour la lisibilité
BOLD="\033[1m"
CYAN="\033[1;36m"
GREEN="\033[1;32m"
YELLOW="\033[1;33m"
RESET="\033[0m"

# --------------------------------------------------------------------------
# Fonctions utilitaires
# --------------------------------------------------------------------------

print_header() {
    echo -e "\n${CYAN}================================================================${RESET}"
    echo -e "${CYAN}  $1${RESET}"
    echo -e "${CYAN}================================================================${RESET}"
}

print_section() {
    echo -e "\n${BOLD}  >>> $1${RESET}"
}

print_file_info() {
    local label="$1"
    local file="$2"
    if [ -f "$file" ]; then
        local dims voxsize
        dims=$(mrinfo "$file" -size 2>/dev/null | tr '\n' ' ' | xargs)
        voxsize=$(mrinfo "$file" -spacing 2>/dev/null | tr '\n' ' ' | xargs)
        echo -e "  ${GREEN}[OK]${RESET}  ${label}"
        echo -e "        Dimensions  : $dims"
        echo -e "        Voxel size  : $voxsize mm"
    else
        echo -e "  ${YELLOW}[--]${RESET}  ${label}  (absent)"
    fi
}

print_bval_info() {
    local bval_file="$1"
    if [ -f "$bval_file" ]; then
        # Shells uniques (valeurs arrondies à 50 près)
        local shells
        shells=$(python3 -c "
import sys
vals = list(map(float, open('$bval_file').read().split()))
rounded = sorted(set(round(v/50)*50 for v in vals))
counts = {r: sum(1 for v in vals if abs(round(v/50)*50 - r) < 1) for r in rounded}
print('  '.join(f'b={int(k)} ({v} vol)' for k,v in counts.items()))
" 2>/dev/null)
        echo -e "        Shells      : $shells"
    fi
}

identify_deidentified() {
    local json_file="$1"
    local nii_file="$2"
    if [ ! -f "$json_file" ]; then
        echo "inconnu"
        return
    fi
    local acq_type img_type tr te fa
    acq_type=$(python3 -c "import json,sys; d=json.load(open('$json_file')); print(d.get('MRAcquisitionType','?'))" 2>/dev/null)
    img_type=$(python3 -c "import json,sys; d=json.load(open('$json_file')); print(' '.join(d.get('ImageType',[])))" 2>/dev/null)
    tr=$(python3 -c "import json,sys; d=json.load(open('$json_file')); print(d.get('RepetitionTime','?'))" 2>/dev/null)
    te=$(python3 -c "import json,sys; d=json.load(open('$json_file')); print(d.get('EchoTime','?'))" 2>/dev/null)
    fa=$(python3 -c "import json,sys; d=json.load(open('$json_file')); print(d.get('FlipAngle','?'))" 2>/dev/null)

    if echo "$img_type" | grep -qi "FMRI"; then
        echo "fMRI 2D  (TR=${tr}s  TE=${te}s  FA=${fa}°)"
    elif [ "$acq_type" = "3D" ] && python3 -c "exit(0 if float('${te}') < 0.005 else 1)" 2>/dev/null; then
        echo "T1w 3D   (TR=${tr}s  TE=${te}s  FA=${fa}°)"
    else
        echo "${acq_type}  ImageType=[${img_type}]  TR=${tr}s  TE=${te}s  FA=${fa}°"
    fi
}

# --------------------------------------------------------------------------
# Main
# --------------------------------------------------------------------------

echo -e "${BOLD}Projet Socosca — Vue d'ensemble des données IRM${RESET}"
echo -e "Répertoire des données : ${DATA_DIR}"
echo -e "Date : $(date '+%Y-%m-%d %H:%M')"

# Compter les sujets
SUBJECTS=( $(find "$DATA_DIR" -maxdepth 1 -type d -name "sub-*" | sort) )
echo -e "\nNombre de sujets : ${#SUBJECTS[@]}"

for SUBJECT in "${SUBJECTS[@]}"; do

    SUBJECT_ID=$(basename "$SUBJECT")
    print_header "$SUBJECT_ID"

    # ------------------------------------------------------------------
    # Données anatomiques
    # ------------------------------------------------------------------
    print_section "Anatomique (anat/)"
    ANAT_DIR="$SUBJECT/anat"

    # T1
    T1_FILE=$(find "$ANAT_DIR" -name "T1.nii*" 2>/dev/null | sort | head -1)
    if [ -n "$T1_FILE" ]; then
        dims=$(mrinfo "$T1_FILE" -size 2>/dev/null | tr '\n' ' ' | xargs)
        voxsize=$(mrinfo "$T1_FILE" -spacing 2>/dev/null | tr '\n' ' ' | xargs)
        echo -e "  ${GREEN}[OK]${RESET}  T1w 3D anatomique : $(basename "$T1_FILE")"
        echo -e "        Dimensions  : $dims"
        echo -e "        Voxel size  : $voxsize mm"
    else
        echo -e "  ${YELLOW}[--]${RESET}  T1w 3D anatomique : absent"
    fi

    # ------------------------------------------------------------------
    # Données DWI
    # ------------------------------------------------------------------
    print_section "Diffusion (dwi/)"
    DWI_DIR="$SUBJECT/dwi"

    # b1000
    DWI_B1000="$DWI_DIR/dwi_b1000.nii"
    [ ! -f "$DWI_B1000" ] && DWI_B1000="$DWI_DIR/dwi_b1000.nii.gz"
    if [ -f "$DWI_B1000" ]; then
        dims=$(mrinfo "$DWI_B1000" -size 2>/dev/null | tr '\n' ' ' | xargs)
        voxsize=$(mrinfo "$DWI_B1000" -spacing 2>/dev/null | tr '\n' ' ' | xargs)
        echo -e "  ${GREEN}[OK]${RESET}  DWI b=1000 : $(basename "$DWI_B1000")"
        echo -e "        Dimensions  : $dims"
        echo -e "        Voxel size  : $voxsize mm"
        print_bval_info "$DWI_DIR/dwi_b1000.bval"
    else
        echo -e "  ${YELLOW}[--]${RESET}  DWI b=1000 : absent"
    fi

    # b2000
    DWI_B2000="$DWI_DIR/dwi_b2000.nii"
    [ ! -f "$DWI_B2000" ] && DWI_B2000="$DWI_DIR/dwi_b2000.nii.gz"
    if [ -f "$DWI_B2000" ]; then
        dims=$(mrinfo "$DWI_B2000" -size 2>/dev/null | tr '\n' ' ' | xargs)
        voxsize=$(mrinfo "$DWI_B2000" -spacing 2>/dev/null | tr '\n' ' ' | xargs)
        echo -e "  ${GREEN}[OK]${RESET}  DWI b=2000 : $(basename "$DWI_B2000")"
        echo -e "        Dimensions  : $dims"
        echo -e "        Voxel size  : $voxsize mm"
        print_bval_info "$DWI_DIR/dwi_b2000.bval"
    else
        echo -e "  ${YELLOW}[--]${RESET}  DWI b=2000 : absent"
    fi

    # b0 AP (correction de distorsion)
    DWI_AP="$DWI_DIR/dwi_AP.nii"
    [ ! -f "$DWI_AP" ] && DWI_AP="$DWI_DIR/dwi_AP.nii.gz"
    if [ -f "$DWI_AP" ]; then
        dims=$(mrinfo "$DWI_AP" -size 2>/dev/null | tr '\n' ' ' | xargs)
        echo -e "  ${GREEN}[OK]${RESET}  b0 AP (fieldmap) : $(basename "$DWI_AP")  dims=[$dims]"
    else
        echo -e "  ${YELLOW}[--]${RESET}  b0 AP (fieldmap) : absent"
    fi

    # b0 PA (correction de distorsion)
    DWI_PA="$DWI_DIR/dwi_PA.nii"
    [ ! -f "$DWI_PA" ] && DWI_PA="$DWI_DIR/dwi_PA.nii.gz"
    if [ -f "$DWI_PA" ]; then
        dims=$(mrinfo "$DWI_PA" -size 2>/dev/null | tr '\n' ' ' | xargs)
        echo -e "  ${GREEN}[OK]${RESET}  b0 PA (fieldmap) : $(basename "$DWI_PA")  dims=[$dims]"
    else
        echo -e "  ${YELLOW}[--]${RESET}  b0 PA (fieldmap) : absent"
    fi

    # ------------------------------------------------------------------
    # Séries DeIdentified
    # ------------------------------------------------------------------
    DEIDENT_FILES=( $(find "$DWI_DIR" -name "_DeIdentified_*.nii*" | sort 2>/dev/null) )
    if [ ${#DEIDENT_FILES[@]} -gt 0 ]; then
        print_section "Séries anonymisées (dwi/_DeIdentified_*)"
        for NII_FILE in "${DEIDENT_FILES[@]}"; do
            BASENAME=$(basename "$NII_FILE" .gz)
            BASENAME=$(basename "$BASENAME" .nii)
            JSON_FILE="$DWI_DIR/${BASENAME}.json"
            SEQ_TYPE=$(identify_deidentified "$JSON_FILE" "$NII_FILE")
            dims=$(mrinfo "$NII_FILE" -size 2>/dev/null | tr '\n' ' ' | xargs)
            voxsize=$(mrinfo "$NII_FILE" -spacing 2>/dev/null | tr '\n' ' ' | xargs)
            echo -e "  ${GREEN}[OK]${RESET}  $(basename "$NII_FILE") → $SEQ_TYPE"
            echo -e "        Dimensions  : $dims"
            echo -e "        Voxel size  : $voxsize mm"
        done
    fi

    # ------------------------------------------------------------------
    # Résumé fichiers manquants / non compressés
    # ------------------------------------------------------------------
    NII_UNCOMPRESSED=( $(find "$SUBJECT" -name "*.nii" -not -name "*.nii.gz" 2>/dev/null) )
    if [ ${#NII_UNCOMPRESSED[@]} -gt 0 ]; then
        echo ""
        echo -e "  ${YELLOW}[!]${RESET}  Fichiers .nii non compressés (${#NII_UNCOMPRESSED[@]}) :"
        for f in "${NII_UNCOMPRESSED[@]}"; do
            SIZE=$(du -sh "$f" 2>/dev/null | cut -f1)
            echo -e "        $SIZE  $(basename "$f")"
        done
        echo -e "        → Lancer scripts/01_zip_nii.sh pour compresser"
    fi

done

echo -e "\n${BOLD}Terminé.${RESET}\n"
