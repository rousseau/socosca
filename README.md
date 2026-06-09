# Projet Socosca — Traitement IRM diffusion

## Description du projet

Traitement des données IRM anatomiques et de diffusion du projet Socosca.  
Données brutes : `~/Data/Socosca/`  
Résultats      : `~/Exp/socosca/results/`

Pipeline basé sur **MRtrix3** (https://www.mrtrix.org/).

---

## Structure des données (~/Data/Socosca/)

```
sub-XX/
├── anat/
│   ├── T1.nii.gz           # T1w 3D anatomique (3T Siemens Vida)
│   └── T1.json
└── dwi/
    ├── dwi_b1000.nii       # DWI multi-shell b=1000  (35 volumes : 4×b0 + 31×DWI)
    ├── dwi_b1000.bval
    ├── dwi_b1000.bvec
    ├── dwi_b1000.json
    ├── dwi_b2000.nii       # DWI multi-shell b=2000  (71 volumes : 6×b0 + 65×DWI)
    ├── dwi_b2000.bval
    ├── dwi_b2000.bvec
    ├── dwi_b2000.json
    ├── dwi_AP.nii          # b0 AP  (phase encoding Antéro-Postérieur, pour fieldmap)
    ├── dwi_AP.json
    ├── dwi_PA.nii          # b0 PA  (phase encoding Postéro-Antérieur, pour fieldmap)
    ├── dwi_PA.json
    └── _DeIdentified_*     # séries anonymisées (T1 3D ou fMRI selon le sujet)
```

### Sujets disponibles

| Sujet  | T1 anat | DWI b1000 | DWI b2000 | AP/PA b0 |
|--------|---------|-----------|-----------|----------|
| sub-01 | ✓       | 35 vol    | 71 vol    | ✓        |
| sub-02 | ✓       | 35 vol    | 71 vol    | ✓        |
| sub-03 | ✓       | 35 vol    | 71 vol    | ✓        |
| sub-04 | ✓       | 35 vol    | 71 vol    | ✓        |

---

## Structure du projet (~/Exp/socosca/)

```
scripts/
├── 00_data_overview.sh     # Vue d'ensemble des données (type, dimensions, b-values)
├── 01_zip_nii.sh           # Compression des .nii en .nii.gz
└── ...                     # (à venir : prétraitement, tractographie, etc.)
results/
└── sub-XX/                 # Résultats par sujet (créés par les scripts)
```

---

## Pipeline MRtrix3 (étapes prévues)

1. **Vue d'ensemble** — `scripts/00_data_overview.sh`
2. **Compression** — `scripts/01_zip_nii.sh`
3. **Prétraitement DWI** :
   - Débruitage (`dwidenoise`)
   - Correction Gibbs (`mrdegibbs`)
   - Correction distorsion EPI + mouvement (`dwifslpreproc`, AP+PA b0)
   - Correction biais B1 (`dwibiascorrect`)
4. **Modèle tensoriel** (`dwi2tensor`, `tensor2metric` → FA, MD, AD, RD)
5. **Tractographie** (`tckgen`, `tcksift2`)

---

## Dépendances

- MRtrix3 : https://www.mrtrix.org/
- FSL (pour dwifslpreproc / topup)
- ANTs (recalage T1)
