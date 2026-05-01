#!/bin/bash
# =============================================================================
# 01_zip_nii.sh
# Compression des fichiers .nii en .nii.gz pour le projet Socosca
#
# - Compresse tous les .nii non encore compressés dans ~/Data/Socosca/
# - Conserve les fichiers .nii originaux par défaut
#   (utiliser --remove pour supprimer après compression)
#
# Usage :
#   bash scripts/01_zip_nii.sh           # compresse et conserve les .nii
#   bash scripts/01_zip_nii.sh --remove  # compresse et supprime les .nii
# =============================================================================

set -euo pipefail

DATA_DIR="${HOME}/Data/Socosca"
REMOVE_ORIGINAL=false

if [ "${1:-}" = "--remove" ]; then
    REMOVE_ORIGINAL=true
    echo "Mode : compression + suppression des .nii originaux"
else
    echo "Mode : compression (les .nii originaux sont conservés)"
    echo "       Utiliser --remove pour les supprimer après compression"
fi

echo ""
echo "Recherche des fichiers .nii non compressés dans ${DATA_DIR}..."

NII_FILES=( $(find "$DATA_DIR" -name "*.nii" -not -name "*.nii.gz" | sort) )

if [ ${#NII_FILES[@]} -eq 0 ]; then
    echo "Aucun fichier .nii non compressé trouvé."
    exit 0
fi

echo "Fichiers à compresser : ${#NII_FILES[@]}"
echo ""

TOTAL_SIZE_BEFORE=0
TOTAL_SIZE_AFTER=0

for NII_FILE in "${NII_FILES[@]}"; do
    GZ_FILE="${NII_FILE}.gz"

    if [ -f "$GZ_FILE" ]; then
        echo "  [SKIP] $(basename "$NII_FILE") → .nii.gz déjà présent"
        continue
    fi

    SIZE_BEFORE=$(du -sh "$NII_FILE" 2>/dev/null | cut -f1)
    echo -n "  [GZIP] $(basename "$NII_FILE")  (${SIZE_BEFORE}) → "

    gzip -k "$NII_FILE"

    SIZE_AFTER=$(du -sh "$GZ_FILE" 2>/dev/null | cut -f1)
    echo "${SIZE_AFTER}"

    if [ "$REMOVE_ORIGINAL" = true ]; then
        rm "$NII_FILE"
        echo "         → .nii original supprimé"
    fi
done

echo ""
echo "Compression terminée."

# Vérification finale
REMAINING=( $(find "$DATA_DIR" -name "*.nii" -not -name "*.nii.gz" 2>/dev/null) )
echo "Fichiers .nii non compressés restants : ${#REMAINING[@]}"
