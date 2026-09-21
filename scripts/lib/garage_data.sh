#!/bin/bash
# =============================================================================
# scripts/lib/garage_data.sh
# Mécanisme COMMUN d'accès aux données via Garage (S3/rclone), partagé par
# tous les scripts de pipeline (02, 04, 05, 06…). Objectif : une seule
# implémentation du pull/push/listing de sujets, pour garantir que chaque
# script accède aux données de la même façon.
#
# Prérequis avant de sourcer ce fichier :
#   - config/machine.sh déjà sourcé (fournit GARAGE_REMOTE/GARAGE_BUCKET/
#     GARAGE_PREFIX via config/garage.sh)
#   - Variables définies par le script appelant : WORK_DIR, DATA_DIR
#     (="${WORK_DIR}/sourcedata"), SUBJECT_ARG, DO_PULL, DO_PUSH
#     (CLEAN_SOURCEDATA pour clean_sourcedata)
#
# Fonctions exportées :
#   require_rclone_if_needed
#   select_subjects                        -> remplit le tableau SUBJECTS
#   pull_subject_sourcedata <sub-XX> [sous-dossier]
#   push_subject_results <pipeline> <sub-XX> <dossier_local> [exclude...]
#   find_t1w <dossier_sujet> <sub-XX>       -> chemin T1w BIDS (vide si absent)
#   clean_sourcedata <sub-XX>
# =============================================================================

require_rclone_if_needed() {
    if { [ "${DO_PULL}" = true ] || [ "${DO_PUSH}" = true ]; } && ! command -v rclone >/dev/null 2>&1; then
        echo "[ERR] rclone introuvable — installer rclone, ou utiliser --no-pull --no-push pour un test purement local" >&2
        exit 1
    fi
}

# Sélectionne les sujets à traiter dans le tableau global SUBJECTS :
#   - SUBJECT_ARG non vide -> ce seul sujet
#   - DO_PULL=true         -> liste depuis Garage (sourcedata)
#   - sinon                -> liste depuis le dossier local DATA_DIR
select_subjects() {
    if [ -n "${SUBJECT_ARG:-}" ]; then
        SUBJECTS=("$SUBJECT_ARG")
        return
    fi

    SUBJECTS=()
    if [ "${DO_PULL}" = true ]; then
        while IFS= read -r _s; do SUBJECTS+=("${_s%/}"); done < <(
            rclone lsf "${GARAGE_REMOTE}:${GARAGE_BUCKET}/${GARAGE_PREFIX}/sourcedata" --dirs-only 2>/dev/null | grep '^sub-' | sort)
        # "if" (pas "test && { ...; }") : sous set -e, le statut de sortie du
        # test false serait celui de la dernière commande de la fonction, donc
        # celui de select_subjects — et tuerait le script juste après l'appel,
        # y compris quand des sujets ONT été trouvés (cas normal).
        if [ ${#SUBJECTS[@]} -eq 0 ]; then
            echo "[ERR] Aucun sujet trouvé sur Garage (${GARAGE_BUCKET}/${GARAGE_PREFIX}/sourcedata) — vérifier rclone/le remote, ou utiliser --sub" >&2
            exit 1
        fi
    else
        while IFS= read -r _s; do SUBJECTS+=("$_s"); done < <(
            find "$DATA_DIR" -maxdepth 1 -type d -name "sub-*" 2>/dev/null | sort | xargs -I{} basename {})
        if [ ${#SUBJECTS[@]} -eq 0 ]; then
            echo "[ERR] Aucun sujet trouvé localement dans ${DATA_DIR} (--no-pull requiert une copie locale déjà présente)" >&2
            exit 1
        fi
    fi
}

# Rapatrie le sourcedata d'un sujet depuis Garage vers DATA_DIR/<sub-XX>.
#   pull_subject_sourcedata sub-01            # tout le sujet (anat+dwi+fmap)
#   pull_subject_sourcedata sub-01 anat       # uniquement anat/ (pipelines T1-only)
# No-op si DO_PULL=false.
pull_subject_sourcedata() {
    local subject_id="$1" subdir="${2:-}"
    [ "${DO_PULL}" = true ] || return 0
    local remote="${GARAGE_REMOTE}:${GARAGE_BUCKET}/${GARAGE_PREFIX}/sourcedata/${subject_id}${subdir:+/${subdir}}"
    local local_dir="${DATA_DIR}/${subject_id}${subdir:+/${subdir}}"
    mkdir -p "$local_dir"
    rclone copy "$remote" "$local_dir" --exclude ".DS_Store" --quiet
}

# Pousse les dérivés locaux d'un sujet vers Garage.
#   push_subject_results mrtrix sub-01 "${RESULTS_ROOT}/sub-01" "*.mif" "tmp/**"
# No-op si DO_PUSH=false.
push_subject_results() {
    local pipeline="$1" subject_id="$2" local_dir="$3"; shift 3
    [ "${DO_PUSH}" = true ] || return 0
    [ -d "$local_dir" ] || return 0
    local rclone_excludes=()
    local e
    for e in "$@"; do rclone_excludes+=(--exclude "$e"); done
    rclone copy "$local_dir" \
        "${GARAGE_REMOTE}:${GARAGE_BUCKET}/${GARAGE_PREFIX}/derivatives/${pipeline}/${subject_id}" \
        "${rclone_excludes[@]}" --quiet
}

# Localise le T1w BIDS d'un sujet (nommage sub-XX_T1w.nii[.gz]).
# Écrit le chemin sur stdout, ou rien si absent. Renvoie toujours 0 : ne PAS
# utiliser "ls f1 f2 | head -1" ici, "ls" renvoie un code non-nul dès qu'un
# des deux motifs ne correspond pas — même quand l'autre est trouvé — ce qui
# tuerait le script appelant sous "set -e -o pipefail".
find_t1w() {
    local subject_dir="$1" subject_id="$2" f
    for f in "${subject_dir}/anat/${subject_id}_T1w.nii.gz" "${subject_dir}/anat/${subject_id}_T1w.nii"; do
        if [ -f "$f" ]; then
            printf '%s\n' "$f"
            return 0
        fi
    done
    return 0
}

# Supprime la copie locale de sourcedata d'un sujet (si CLEAN_SOURCEDATA=true).
clean_sourcedata() {
    local subject_id="$1"
    [ "${CLEAN_SOURCEDATA:-false}" = true ] || return 0
    rm -rf "${DATA_DIR}/${subject_id}"
}
