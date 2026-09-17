#!/bin/bash
# =============================================================================
# 01b_import_new_data.sh
# Importe de nouvelles données brutes dans ~/Data/Socosca/, au format BIDS.
#
# Données sources attendues (arborescence livrée par groupe) :
#   <SRC>/Patients/sub-XX/brutes/{T1.nii[.gz],T1.json,dwi_b1000.*,
#                                  dwi_b2000.*,dwi_AP.*,dwi_PA.*}
#   <SRC>/Temoins/sub-XX/brutes/...                 (même structure)
#   <SRC>/Matching.txt                              (pairage patient/témoin, optionnel)
#
# Le script répartit les fichiers de brutes/ en nommage BIDS et fusionne avec
# les sujets déjà présents dans le répertoire de destination, sans écraser un
# sujet existant sauf --force explicite. Les b0 AP/PA (topup) vont dans
# fmap/ avec l'entité dir- et un IntendedFor pointant vers les deux run DWI.
#
# Sorties (BIDS) :
#   <DEST>/dataset_description.json  (créé une fois, jamais écrasé)
#   <DEST>/participants.tsv           (participant_id, group)
#   <DEST>/participants_matching.tsv  (copie de Matching.txt si présent)
#   <DEST>/sub-XX/anat/sub-XX_T1w.nii[.gz] + .json
#   <DEST>/sub-XX/dwi/sub-XX_acq-{b1000,b2000}_dwi.nii[.gz] + .bval/.bvec/.json
#   <DEST>/sub-XX/fmap/sub-XX_dir-{AP,PA}_epi.nii[.gz] + .json (IntendedFor)
#
# Usage :
#   bash scripts/01b_import_new_data.sh --src ~/Downloads/Socosca_09_26 [--dry-run] [--force]
#   bash scripts/01b_import_new_data.sh --src ... --dest ~/Data/Socosca
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Couleurs / logs (cohérent avec le reste du pipeline)
# ---------------------------------------------------------------------------
CYAN="\033[1;36m"
GREEN="\033[1;32m"
YELLOW="\033[1;33m"
RED="\033[1;31m"
RESET="\033[0m"

log()  { echo -e "\n${CYAN}[$(date '+%H:%M:%S')] $*${RESET}"; }
info() { echo -e "  ${GREEN}→${RESET} $*"; }
warn() { echo -e "  ${YELLOW}[WARN]${RESET} $*" >&2; }
die()  { echo -e "  ${RED}[ERR]${RESET}  $*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Arguments
# ---------------------------------------------------------------------------
SRC_DIR=""
DEST_DIR="${HOME}/Data/Socosca"
DRY_RUN=false
FORCE=false

usage() {
    cat <<EOF
Usage: $(basename "$0") --src <dossier> [--dest <dossier>] [--dry-run] [--force]

  --src       dossier racine contenant Patients/ et/ou Temoins/ (obligatoire)
  --dest      destination (défaut : ${DEST_DIR})
  --dry-run   affiche les actions sans rien copier/déplacer
  --force     autorise l'écrasement d'un sujet déjà présent dans --dest
EOF
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --src)      SRC_DIR="$2"; shift 2 ;;
        --dest)     DEST_DIR="$2"; shift 2 ;;
        --dry-run)  DRY_RUN=true; shift ;;
        --force)    FORCE=true; shift ;;
        --help|-h)  usage ;;
        *) die "Argument inconnu : $1 (voir --help)" ;;
    esac
done

[ -n "$SRC_DIR" ] || die "--src est obligatoire (voir --help)"
[ -d "$SRC_DIR" ] || die "Dossier source introuvable : ${SRC_DIR}"

mkdir -p "$DEST_DIR"

# Sujet dont l'import a échoué ou a été ignoré, pour le résumé final
declare -a IMPORTED=()
declare -a SKIPPED=()
declare -a FAILED=()

run() {
    # Exécute la commande sauf en --dry-run (où elle est seulement affichée)
    if [ "$DRY_RUN" = true ]; then
        echo "    [dry-run] $*"
    else
        "$@"
    fi
}

# cp -n retourne 1 (BSD/macOS) si la cible existe déjà, incompatible avec set -e
copy_if_absent() {
    local src="$1" dst="$2"
    [ -e "$dst" ] && return 0
    run cp "$src" "$dst"
}

# Fichier NIfTI source pour un stem donné (priorité au .nii.gz déjà compressé) ; vide si absent
pick_nifti() {
    local dir="$1" stem="$2"
    if [ -f "${dir}/${stem}.nii.gz" ]; then
        echo "${dir}/${stem}.nii.gz"
    elif [ -f "${dir}/${stem}.nii" ]; then
        echo "${dir}/${stem}.nii"
    fi
}

# Ajoute des chemins à IntendedFor dans un json fmap, sans doublon (no-op en dry-run)
add_intended_for() {
    local json_file="$1"; shift
    if [ "$DRY_RUN" = true ]; then
        echo "    [dry-run] IntendedFor += $* -> $(basename "$json_file")"
        return
    fi
    [ -f "$json_file" ] || return 0
    python3 - "$json_file" "$@" <<'PY'
import json, sys
path = sys.argv[1]
entries = sys.argv[2:]
with open(path) as f:
    d = json.load(f)
existing = d.get("IntendedFor", [])
for e in entries:
    if e not in existing:
        existing.append(e)
d["IntendedFor"] = existing
with open(path, "w") as f:
    json.dump(d, f, indent=2)
    f.write("\n")
PY
}

# ---------------------------------------------------------------------------
# Répartition brutes/ -> anat/ + dwi/ + fmap/ (nommage BIDS) pour un sujet
# ---------------------------------------------------------------------------
import_subject() {
    local group="$1" subject_dir="$2"
    local subject_id brutes_dir dest_subject
    subject_id=$(basename "$subject_dir")
    brutes_dir="${subject_dir}/brutes"

    [ -d "$brutes_dir" ] || { warn "${subject_id} (${group}) : dossier brutes/ absent — ignoré"; SKIPPED+=("$subject_id"); return; }

    dest_subject="${DEST_DIR}/${subject_id}"
    # Un dossier existant mais vide (ex. run précédent interrompu, ou juste un
    # .DS_Store laissé par le Finder) ne compte pas comme "déjà présent" :
    # sans ce test, les fichiers manquants ne seraient plus jamais copiés
    # sans --force.
    if [ -d "$dest_subject" ] && [ "$FORCE" != true ] && \
       [ -n "$(find "$dest_subject" -mindepth 1 -type f -not -name ".DS_Store" -print -quit 2>/dev/null)" ]; then
        warn "${subject_id} : déjà présent dans ${DEST_DIR} — ignoré (utiliser --force pour écraser)"
        SKIPPED+=("$subject_id")
        return
    fi

    info "${subject_id} (${group})"
    run mkdir -p "${dest_subject}/anat" "${dest_subject}/dwi" "${dest_subject}/fmap"

    local moved=0 src ext acq dir_lbl sidecar file base

    # --- anat : T1w ---
    src=$(pick_nifti "$brutes_dir" "T1")
    if [ -n "$src" ]; then
        ext="nii.gz"; [[ "$src" == *.nii ]] && ext="nii"
        copy_if_absent "$src" "${dest_subject}/anat/${subject_id}_T1w.${ext}"; (( moved++ )) || true
        if [ -f "${brutes_dir}/T1.json" ]; then
            copy_if_absent "${brutes_dir}/T1.json" "${dest_subject}/anat/${subject_id}_T1w.json"; (( moved++ )) || true
        fi
    else
        warn "${subject_id} : T1 introuvable dans brutes/"
    fi

    # --- dwi : acq-b1000 / acq-b2000 ---
    local dwi_intended=()
    for acq in b1000 b2000; do
        src=$(pick_nifti "$brutes_dir" "dwi_${acq}")
        if [ -z "$src" ]; then
            warn "${subject_id} : dwi_${acq} introuvable dans brutes/"
            continue
        fi
        ext="nii.gz"; [[ "$src" == *.nii ]] && ext="nii"
        copy_if_absent "$src" "${dest_subject}/dwi/${subject_id}_acq-${acq}_dwi.${ext}"; (( moved++ )) || true
        dwi_intended+=("dwi/${subject_id}_acq-${acq}_dwi.${ext}")
        for sidecar in bval bvec json; do
            if [ -f "${brutes_dir}/dwi_${acq}.${sidecar}" ]; then
                copy_if_absent "${brutes_dir}/dwi_${acq}.${sidecar}" "${dest_subject}/dwi/${subject_id}_acq-${acq}_dwi.${sidecar}"
                (( moved++ )) || true
            fi
        done
    done

    # --- fmap : dir-AP / dir-PA (topup), IntendedFor -> les deux run DWI ---
    for dir_lbl in AP PA; do
        src=$(pick_nifti "$brutes_dir" "dwi_${dir_lbl}")
        if [ -z "$src" ]; then
            warn "${subject_id} : dwi_${dir_lbl} (fmap) introuvable dans brutes/"
            continue
        fi
        ext="nii.gz"; [[ "$src" == *.nii ]] && ext="nii"
        copy_if_absent "$src" "${dest_subject}/fmap/${subject_id}_dir-${dir_lbl}_epi.${ext}"; (( moved++ )) || true
        if [ -f "${brutes_dir}/dwi_${dir_lbl}.json" ]; then
            copy_if_absent "${brutes_dir}/dwi_${dir_lbl}.json" "${dest_subject}/fmap/${subject_id}_dir-${dir_lbl}_epi.json"
            (( moved++ )) || true
            [ ${#dwi_intended[@]} -gt 0 ] && add_intended_for "${dest_subject}/fmap/${subject_id}_dir-${dir_lbl}_epi.json" "${dwi_intended[@]}"
        fi
    done

    # --- fichiers non reconnus (ex. séries _DeIdentified_*) : juste un avertissement ---
    while IFS= read -r -d '' file; do
        base=$(basename "$file")
        case "$base" in
            .DS_Store|T1.nii|T1.nii.gz|T1.json|dwi_b1000.*|dwi_b2000.*|dwi_AP.*|dwi_PA.*) : ;;
            *) warn "${subject_id} : fichier non reconnu ignoré — ${base}" ;;
        esac
    done < <(find "$brutes_dir" -maxdepth 1 -type f -print0)

    if [ "$moved" -eq 0 ]; then
        warn "${subject_id} : aucun fichier reconnu dans brutes/"
        FAILED+=("$subject_id")
    else
        IMPORTED+=("${subject_id}:${group}")
    fi
}

# ---------------------------------------------------------------------------
# Parcours des groupes Patients / Temoins
# ---------------------------------------------------------------------------
log "Import de nouvelles données — source : ${SRC_DIR}"
info "Destination : ${DEST_DIR}"
[ "$DRY_RUN" = true ] && info "Mode dry-run : aucune modification ne sera écrite"

for group_dir in "${SRC_DIR}"/Patients "${SRC_DIR}"/Temoins; do
    [ -d "$group_dir" ] || continue
    group=$(basename "$group_dir")
    while IFS= read -r subject_dir; do
        import_subject "$group" "$subject_dir"
    done < <(find "$group_dir" -maxdepth 1 -mindepth 1 -type d -name "sub-*" | sort)
done

if [ ${#IMPORTED[@]} -eq 0 ] && [ ${#SKIPPED[@]} -eq 0 ]; then
    die "Aucun sujet trouvé sous ${SRC_DIR}/{Patients,Temoins}/sub-*/brutes/"
fi

# ---------------------------------------------------------------------------
# dataset_description.json — créé une fois, jamais écrasé (requis par BIDS)
# ---------------------------------------------------------------------------
DATASET_DESC="${DEST_DIR}/dataset_description.json"
if [ ! -f "$DATASET_DESC" ]; then
    log "Création de dataset_description.json"
    if [ "$DRY_RUN" = true ]; then
        echo "    [dry-run] écriture ${DATASET_DESC}"
    else
        cat > "$DATASET_DESC" <<'JSON'
{
  "Name": "Socosca",
  "BIDSVersion": "1.9.0",
  "DatasetType": "raw"
}
JSON
    fi
    info "$(basename "$DATASET_DESC")"
fi

# ---------------------------------------------------------------------------
# participants.tsv (participant_id, group) — fusion sans doublon
# ---------------------------------------------------------------------------
if [ ${#IMPORTED[@]} -gt 0 ]; then
    log "Mise à jour de participants.tsv"
    PARTICIPANTS_TSV="${DEST_DIR}/participants.tsv"
    [ -f "$PARTICIPANTS_TSV" ] || echo -e "participant_id\tgroup" > "$PARTICIPANTS_TSV"

    for entry in "${IMPORTED[@]}"; do
        subject_id="${entry%%:*}"
        group="${entry##*:}"
        if grep -qP "^${subject_id}\t" "$PARTICIPANTS_TSV" 2>/dev/null; then
            continue
        fi
        if [ "$DRY_RUN" = true ]; then
            echo "    [dry-run] participants.tsv += ${subject_id}\t${group}"
        else
            echo -e "${subject_id}\t${group}" >> "$PARTICIPANTS_TSV"
        fi
    done
    info "$(basename "$PARTICIPANTS_TSV")"
fi

# ---------------------------------------------------------------------------
# Matching.txt -> participants_matching.tsv (copie brute, si présent)
# ---------------------------------------------------------------------------
if [ -f "${SRC_DIR}/Matching.txt" ]; then
    log "Copie de Matching.txt"
    copy_if_absent "${SRC_DIR}/Matching.txt" "${DEST_DIR}/participants_matching.tsv"
    info "participants_matching.tsv"
fi

# ---------------------------------------------------------------------------
# Résumé
# ---------------------------------------------------------------------------
log "Import terminé"
echo "  Importés : ${#IMPORTED[@]}"
echo "  Ignorés  : ${#SKIPPED[@]}"
echo "  Échoués  : ${#FAILED[@]}"
[ ${#FAILED[@]} -gt 0 ] && warn "Sujets en échec : ${FAILED[*]}"
echo ""
echo "Prochaine étape : bash scripts/01_zip_nii.sh   # compresser les .nii importés"
