#!/bin/bash
# =============================================================================
# config/machine.sh
# Détection automatique de la machine et chargement du profil de config
#
# Variables exportées par chaque profil :
#   MACHINE_ID          identifiant lisible (macos / dgx-arm / linux-x86)
#   FREESURFER_HOME     chemin installation FreeSurfer
#   FS_LICENSE          chemin fichier licence FreeSurfer
#   FSLDIR              chemin installation FSL
#   ANTS_BIN            chemin vers les binaires ANTs
#   SIAM_CMD            chemin vers siam-pred
#   SIAM_DEVICE         device SIAM (mps / cuda / cpu)
#   SIAM_AVAILABLE      true/false — SIAM est-il utilisable sur cette machine
#   NTHR_DEFAULT        nombre de threads par défaut
#   PYTHON_CMD          commande python (python3 / python)
# =============================================================================

# Répertoire de ce fichier (fonctionne avec source et bash chemin/machine.sh)
_CONFIG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"

_HOSTNAME=$(hostname -s 2>/dev/null || echo "unknown")
_ARCH=$(uname -m 2>/dev/null || echo "unknown")
_OS=$(uname -s 2>/dev/null || echo "unknown")

# Détection par hostname puis par OS/architecture
_PROFILE=""
case "${_HOSTNAME}" in
    MacBook*|*mbp*|*MBP*)           _PROFILE="macos"     ;;
    *dgx* | *DGX*)                   _PROFILE="dgx-arm"   ;;
    *)
        if [ "$_OS" = "Darwin" ]; then
            _PROFILE="macos"
        elif [ "$_ARCH" = "x86_64" ]; then
            _PROFILE="linux-x86"
        elif [ "$_ARCH" = "aarch64" ] || [ "$_ARCH" = "arm64" ]; then
            _PROFILE="dgx-arm"
        else
            echo "[ERR] Machine non reconnue : $_HOSTNAME ($_OS / $_ARCH)" >&2
            echo "      Créer un profil dans config/ et adapter machine.sh" >&2
            return 1 2>/dev/null || exit 1
        fi
        ;;
esac

# Permettre un override manuel via variable d'environnement
_PROFILE="${MACHINE_PROFILE:-${_PROFILE}}"

_PROFILE_FILE="${_CONFIG_DIR}/${_PROFILE}.sh"
if [ ! -f "$_PROFILE_FILE" ]; then
    echo "[ERR] Profil config introuvable : ${_PROFILE_FILE}" >&2
    return 1 2>/dev/null || exit 1
fi

# shellcheck disable=SC1090
source "$_PROFILE_FILE"

echo "  [config] machine=${MACHINE_ID} | threads=${NTHR_DEFAULT} | siam=${SIAM_AVAILABLE}"
