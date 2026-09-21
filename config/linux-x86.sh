#!/bin/bash
# =============================================================================
# config/linux-x86.sh — Serveur Linux x86_64
# Adapter les chemins selon l'installation réelle
# =============================================================================
export MACHINE_ID="linux-x86"

# ---------------------------------------------------------------------------
# FreeSurfer — via Docker (freesurfer/freesurfer:8.2.0)
# Pas de paquet .deb natif compatible Ubuntu 26.04 (ABI ITK/HDF5/VTK liées à
# Ubuntu 24.04). FREESURFER_HOME pointe vers des wrappers qui appellent
# `docker run` ; voir ~/freesurfer-docker/FreeSurferEnv.sh pour le détail.
# ---------------------------------------------------------------------------
export FREESURFER_HOME="${FREESURFER_HOME:-${HOME}/freesurfer-docker}"
export FS_LICENSE="${FS_LICENSE:-${HOME}/.freesurfer_license.txt}"

# ---------------------------------------------------------------------------
# FSL
# ---------------------------------------------------------------------------
export FSLDIR="${FSLDIR:-${HOME}/fsl}"

# ---------------------------------------------------------------------------
# ANTs
# ---------------------------------------------------------------------------
export ANTS_BIN="${ANTS_BIN:-${HOME}/ants/ants-2.6.5/bin}"

# ---------------------------------------------------------------------------
# MRtrix3
# ---------------------------------------------------------------------------
export MRTRIX_BIN="${MRTRIX_BIN:-/usr/local/bin}"

# ---------------------------------------------------------------------------
# SIAM — dépend de la présence d'un GPU
# ---------------------------------------------------------------------------
export SIAM_AVAILABLE="${SIAM_AVAILABLE:-false}"
export SIAM_DEVICE="${SIAM_DEVICE:-cpu}"
export SIAM_CMD="${SIAM_CMD:-siam-pred}"

# ---------------------------------------------------------------------------
# Python
# ---------------------------------------------------------------------------
export PYTHON_CMD="${PYTHON_CMD:-python3}"

# ---------------------------------------------------------------------------
# Ressources
# ---------------------------------------------------------------------------
export NTHR_DEFAULT="${NTHR_DEFAULT:-8}"

# ---------------------------------------------------------------------------
# PATH
# ---------------------------------------------------------------------------
export PATH="${FREESURFER_HOME}/bin:${FSLDIR}/bin:${ANTS_BIN}:${MRTRIX_BIN}:${PATH}"
