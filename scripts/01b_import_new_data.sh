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
# Sorties (BIDS, NIfTI toujours compressés en .nii.gz) :
#   <DEST>/dataset_description.json  (créé une fois, jamais écrasé)
#   <DEST>/README                     (créé une fois, jamais écrasé)
#   <DEST>/participants.tsv + .json   (participant_id, group, matched_with depuis Matching.txt)
#   <DEST>/sub-XX/anat/sub-XX_T1w.nii.gz + .json
#   <DEST>/sub-XX/dwi/sub-XX_acq-{b1000,b2000}_dwi.nii.gz + .bval/.bvec/.json
#   <DEST>/sub-XX/fmap/sub-XX_dir-{AP,PA}_epi.nii.gz + .json (IntendedFor)
#   <DEST>/sub-XX/func/sub-XX_task-rest_bold.nii.gz + .json (si IRMf acquise)
#
# Les champs JSON requis perdus à l'anonymisation sont recopiés depuis un sujet au
# protocole identique (champ "MetadataInferredFrom") ; les scouts sont ignorés.
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

# Copie un NIfTI vers <dst>.nii.gz : cp si déjà compressé, sinon gzip -n
# (sans nom ni date dans l'en-tête gzip, donc sortie identique d'un import à l'autre).
# Écrire directement en .nii.gz garde IntendedFor cohérent avec les fichiers réels.
gzip_to() { gzip -n -c "$1" > "$2"; }
copy_nifti_gz() {
    local src="$1" dst="$2"
    [ -e "$dst" ] && return 0
    if [[ "$src" == *.nii.gz ]]; then
        run cp "$src" "$dst"
    else
        run gzip_to "$src" "$dst"
    fi
}

# Séries IRMf d'un dossier brutes/ : JSON dont ImageType contient FMRI et dont le
# NIfTI est 4D. Repère aussi les séries dont le nom a été perdu à l'anonymisation
# (_DeIdentified_*). Sortie : "<stem>" par ligne, triée par SeriesNumber.
find_bold_series() {
    python3 - "$1" <<'PY'
import glob, gzip, json, os, struct, sys
found = []
for j in glob.glob(os.path.join(sys.argv[1], "*.json")):
    stem = j[:-5]
    nii = stem + ".nii.gz" if os.path.exists(stem + ".nii.gz") else stem + ".nii"
    if not os.path.exists(nii):
        continue
    d = json.load(open(j))
    if "FMRI" not in d.get("ImageType", []):
        continue
    with (gzip.open if nii.endswith(".gz") else open)(nii, "rb") as f:
        ndim = struct.unpack("<h", f.read(42)[40:42])[0]
    if ndim == 4:
        found.append((d.get("SeriesNumber", 0), os.path.basename(stem)))
for _, stem in sorted(found):
    print(stem)
PY
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

    local moved=0 src acq dir_lbl sidecar file base stem bold_dst
    local -a bold_stems=()

    # --- anat : T1w ---
    src=$(pick_nifti "$brutes_dir" "T1")
    if [ -n "$src" ]; then
        copy_nifti_gz "$src" "${dest_subject}/anat/${subject_id}_T1w.nii.gz"; (( moved++ )) || true
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
        copy_nifti_gz "$src" "${dest_subject}/dwi/${subject_id}_acq-${acq}_dwi.nii.gz"; (( moved++ )) || true
        dwi_intended+=("dwi/${subject_id}_acq-${acq}_dwi.nii.gz")
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
        copy_nifti_gz "$src" "${dest_subject}/fmap/${subject_id}_dir-${dir_lbl}_epi.nii.gz"; (( moved++ )) || true
        if [ -f "${brutes_dir}/dwi_${dir_lbl}.json" ]; then
            copy_if_absent "${brutes_dir}/dwi_${dir_lbl}.json" "${dest_subject}/fmap/${subject_id}_dir-${dir_lbl}_epi.json"
            (( moved++ )) || true
            [ ${#dwi_intended[@]} -gt 0 ] && add_intended_for "${dest_subject}/fmap/${subject_id}_dir-${dir_lbl}_epi.json" "${dwi_intended[@]}"
        fi
    done

    # --- func : IRMf de repos (ep2d_bold REST, ou série anonymisée _DeIdentified_*) ---
    # Toutes les séries IRMf de l'étude sont des acquisitions de repos (même protocole :
    # 64x64x40x175, TR 2 s) ; run-N seulement s'il y en a plusieurs pour un sujet.
    while IFS= read -r stem; do bold_stems+=("$stem"); done < <(find_bold_series "$brutes_dir")
    if [ ${#bold_stems[@]} -gt 0 ]; then
        run mkdir -p "${dest_subject}/func"
        local run_idx=0
        for stem in "${bold_stems[@]}"; do
            (( run_idx++ )) || true
            bold_dst="${dest_subject}/func/${subject_id}_task-rest"
            [ ${#bold_stems[@]} -gt 1 ] && bold_dst="${bold_dst}_run-${run_idx}"
            copy_nifti_gz "$(pick_nifti "$brutes_dir" "$stem")" "${bold_dst}_bold.nii.gz"; (( moved++ )) || true
            copy_if_absent "${brutes_dir}/${stem}.json" "${bold_dst}_bold.json"; (( moved++ )) || true
            info "${subject_id} : ${stem} -> func/$(basename "$bold_dst")_bold"
        done
    fi

    # --- fichiers non reconnus (ex. scouts) : juste un avertissement ---
    while IFS= read -r -d '' file; do
        base=$(basename "$file")
        stem="${base%.json}"; stem="${stem%.gz}"; stem="${stem%.nii}"
        case "$base" in
            .DS_Store|T1.nii|T1.nii.gz|T1.json|dwi_b1000.*|dwi_b2000.*|dwi_AP.*|dwi_PA.*) : ;;
            *) [[ " ${bold_stems[*]:-} " == *" ${stem} "* ]] || warn "${subject_id} : fichier non reconnu ignoré — ${base}" ;;
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
# participants.tsv/.json, métadonnées manquantes, IntendedFor, README
# ---------------------------------------------------------------------------
# Une seule passe Python, idempotente, sur tout le jeu de données (sujets déjà
# présents compris) :
#  - participants.tsv : participant_id, group, matched_with (depuis Matching.txt,
#    lignes "sub-01 / sub-08") ; participants.json décrit les colonnes.
#  - Champs requis absents d'un sidecar (export anonymisé "DeIdentified") :
#    recopiés depuis le même type de série d'un autre sujet, seulement si les
#    paramètres d'acquisition sont identiques (TR, TE, angle, dimensions). La
#    source est notée dans le champ "MetadataInferredFrom" du JSON corrigé.
#  - IntendedFor : chemins réparés en .nii.gz si le fichier visé n'existe qu'ainsi.
#  - README : créé une fois, jamais écrasé.
log "Finalisation (participants, métadonnées, IntendedFor, README)"
if [ "$DRY_RUN" = true ]; then
    echo "    [dry-run] finalisation ignorée"
else
    IMPORTED_LIST=$(printf '%s\n' "${IMPORTED[@]:-}")
    python3 - "$DEST_DIR" "${SRC_DIR}/Matching.txt" "$IMPORTED_LIST" <<'PY'
import csv, glob, gzip, json, os, re, struct, sys

dest, matching_txt, imported = sys.argv[1], sys.argv[2], sys.argv[3]

# --- participants -------------------------------------------------------------
tsv = os.path.join(dest, "participants.tsv")
rows = {}
if os.path.exists(tsv):
    with open(tsv) as f:
        for r in csv.DictReader(f, delimiter="\t"):
            rows[r["participant_id"]] = r
for line in imported.splitlines():
    if ":" in line:
        sid, group = line.split(":", 1)
        rows.setdefault(sid, {"participant_id": sid})["group"] = group
if os.path.exists(matching_txt):
    for line in open(matching_txt):
        m = re.findall(r"sub-\w+", line)
        if len(m) == 2:
            a, b = m
            rows.setdefault(a, {"participant_id": a})["matched_with"] = b
            rows.setdefault(b, {"participant_id": b})["matched_with"] = a
with open(tsv, "w", newline="") as f:
    w = csv.writer(f, delimiter="\t", lineterminator="\n")
    w.writerow(["participant_id", "group", "matched_with"])
    for sid in sorted(rows):
        r = rows[sid]
        w.writerow([sid, r.get("group") or "n/a", r.get("matched_with") or "n/a"])
with open(os.path.join(dest, "participants.json"), "w") as f:
    json.dump({
        "group": {"Description": "Groupe du participant dans la livraison",
                  "Levels": {"Patients": "patient", "Temoins": "témoin (contrôle sain)"}},
        "matched_with": {"Description": "Participant apparié (patient <-> témoin), "
                                        "d'après Matching.txt de la livraison"},
    }, f, indent=2, ensure_ascii=False)
    f.write("\n")
old_matching = os.path.join(dest, "participants_matching.tsv")
if os.path.exists(old_matching):
    os.remove(old_matching)

# --- métadonnées manquantes ---------------------------------------------------
FIELDS = ["PhaseEncodingDirection", "TotalReadoutTime", "EffectiveEchoSpacing", "SliceTiming"]
MATCH = ["RepetitionTime", "EchoTime", "FlipAngle"]

def dims(nii):
    with gzip.open(nii, "rb") as f:
        h = f.read(56)
    n = struct.unpack("<h", h[40:42])[0]
    return struct.unpack("<8h", h[40:56])[1:n + 1]

sidecars = {}
for j in sorted(glob.glob(os.path.join(dest, "sub-*", "*", "sub-*.json"))):
    sid = os.path.basename(os.path.dirname(os.path.dirname(j)))
    kind = os.path.join(os.path.basename(os.path.dirname(j)),
                        os.path.basename(j)[len(sid) + 1:])        # ex. dwi/acq-b1000_dwi.json
    sidecars.setdefault(kind, []).append(j)

for kind, files in sidecars.items():
    data = {j: json.load(open(j)) for j in files}
    refs = [j for j in files if "PhaseEncodingDirection" in data[j] and "MetadataInferredFrom" not in data[j]]
    if not refs:
        continue
    ref = refs[0]
    for j in files:
        d = data[j]
        missing = [k for k in FIELDS if k not in d and k in data[ref]]
        if not missing or j == ref:
            continue
        same = all(d.get(k) == data[ref].get(k) for k in MATCH) and \
               dims(j[:-5] + ".nii.gz") == dims(ref[:-5] + ".nii.gz")
        if not same:
            print(f"  [WARN] {os.path.relpath(j, dest)} : paramètres différents de "
                  f"{os.path.relpath(ref, dest)}, métadonnées non complétées", file=sys.stderr)
            continue
        for k in missing:
            d[k] = data[ref][k]
        d["MetadataInferredFrom"] = {"Source": os.path.relpath(ref, dest), "Fields": missing}
        with open(j, "w") as f:
            json.dump(d, f, indent=2)
            f.write("\n")
        print(f"  → {os.path.relpath(j, dest)} : {', '.join(missing)} <- {os.path.relpath(ref, dest)}")

# --- TaskName (requis pour func) et IntendedFor -------------------------------
for j in glob.glob(os.path.join(dest, "sub-*", "func", "*_bold.json")):
    d = json.load(open(j))
    task = re.search(r"_task-([a-zA-Z0-9]+)_", os.path.basename(j)).group(1)
    if d.get("TaskName") != task:
        d["TaskName"] = task
        json.dump(d, open(j, "w"), indent=2)
        open(j, "a").write("\n")
for j in glob.glob(os.path.join(dest, "sub-*", "fmap", "*.json")):
    d = json.load(open(j))
    sub_dir = os.path.dirname(os.path.dirname(j))
    fixed = [p + ".gz" if p.endswith(".nii") and not os.path.exists(os.path.join(sub_dir, p))
             and os.path.exists(os.path.join(sub_dir, p + ".gz")) else p
             for p in d.get("IntendedFor", [])]
    if fixed != d.get("IntendedFor", []):
        d["IntendedFor"] = fixed
        json.dump(d, open(j, "w"), indent=2)
        open(j, "a").write("\n")

# --- README -------------------------------------------------------------------
readme = os.path.join(dest, "README")
if not os.path.exists(readme):
    open(readme, "w").write("""Socosca — données IRM brutes converties en BIDS

Groupes : patients et témoins appariés (participants.tsv : group, matched_with).
Modalités : T1w (anat), DWI multi-shell b1000/b2000 (dwi), b0 AP/PA pour topup
(fmap, IntendedFor -> dwi), IRMf de repos (func, task-rest) quand elle a été acquise.

Conversion : scripts/01b_import_new_data.sh (dépôt socosca), depuis la livraison
Patients/ Temoins/ sub-XX/brutes/ (NIfTI + JSON issus de dcm2niix).

Notes :
- Une partie des sujets a été exportée de façon anonymisée ("DeIdentified") : les
  noms de séries et certains champs JSON ont été perdus. Les séries IRMf ont été
  identifiées par ImageType=FMRI et leur géométrie (64x64x40x175, TR 2 s). Les
  champs requis absents (PhaseEncodingDirection, TotalReadoutTime, SliceTiming...)
  ont été recopiés d'un sujet acquis avec des paramètres identiques ; chaque JSON
  concerné l'indique dans "MetadataInferredFrom".
- Les scouts (localisateurs) ne sont pas convertis.
- Tous les sujets n'ont pas toutes les séries (voir le validateur BIDS).
""")
PY
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
echo "Vérification : npx bids-validator@1.15.0 ${DEST_DIR}"
