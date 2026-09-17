#!/bin/bash
# =============================================================================
# config/garage.sh
# Config partagée pour la centralisation des données via Garage (S3), commune
# à toutes les machines du groupe.
#
# Prérequis : un remote rclone nommé GARAGE_REMOTE déjà configuré sur chaque
# machine (rclone config / rclone listremotes), pointant vers l'endpoint S3
# de Garage. Le fichier rclone.conf ne doit JAMAIS être versionné (identifiants).
# Le nom de bucket/préfixe ci-dessous n'est pas sensible : le remote rclone
# masque déjà l'hôte/les identifiants réels.
# =============================================================================
export GARAGE_REMOTE="${GARAGE_REMOTE:-garage}"
export GARAGE_BUCKET="${GARAGE_BUCKET:-study-x}"
export GARAGE_PREFIX="${GARAGE_PREFIX:-Socosca}"
