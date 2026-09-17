# Projet Socosca - Traitement IRM diffusion

## Description du projet

Pipeline de traitement automatisé pour données IRM anatomiques (T1w) et de diffusion (DWI).
Le projet s'appuie principalement sur MRtrix3, FSL et ANTs.

Objectif : produire des dérivés de diffusion (métriques DTI, FOD, tractographie) et des sorties de contrôle qualité de manière reproductible.

Note : les chemins locaux sont configurés dans `config/machine.sh` et ne sont pas figés dans cette documentation.

---

## Structure des données d'entrée

Format BIDS, par sujet (voir `scripts/01b_import_new_data.sh` pour convertir de
nouvelles données brutes vers cette structure) :

```text
sub-XX/
|-- anat/
|   |-- sub-XX_T1w.nii[.gz]        # Image anatomique T1w
|   `-- sub-XX_T1w.json            # Métadonnées associées
|-- dwi/
|   |-- sub-XX_acq-b1000_dwi.nii[.gz]  # DWI + .bval/.bvec/.json
|   `-- sub-XX_acq-b2000_dwi.nii[.gz]  # DWI + .bval/.bvec/.json
`-- fmap/
    |-- sub-XX_dir-AP_epi.nii[.gz] + .json  # b0 AP (topup, IntendedFor -> dwi/)
    `-- sub-XX_dir-PA_epi.nii[.gz] + .json  # b0 PA (topup, IntendedFor -> dwi/)
```

`dataset_description.json` et `participants.tsv` sont générés/complétés à la
racine du jeu de données par le script d'import.

---

## Structure du projet

```text
scripts/
|-- 00_data_overview.sh       # Inspection des données (dimensions, volumes, b-values)
|-- 01_zip_nii.sh             # Compression NIfTI (.nii -> .nii.gz)
|-- 01b_import_new_data.sh    # Import de nouvelles données (Patients/Temoins) vers sub-XX
|-- 02_mrtrix_pipeline.sh     # Pipeline diffusion principal
|-- 03_qc_plots.py            # Figures de QC
|-- 04_siam_segmentation.sh
|-- 05_freesurfer_segmentation.sh
|-- 06_tractseg_cerebellum.sh
`-- 07_scilpy_cerebellum.sh
```

Chaque script de traitement lit/écrit dans un répertoire de travail local
(sourcedata/derivatives), structuré ainsi :

```text
derivatives/
|-- mrtrix/sub-XX/{anat,dwi,tractography}/
|-- tractseg/sub-XX/
|-- scilpy/sub-XX/
|-- freesurfer/sub-XX/
`-- plots/sub-XX/
```

---

## Pipeline MRtrix3

Script principal : `scripts/02_mrtrix_pipeline.sh`

1. Conversion NIfTI -> MIF et concaténation multi-shell.
2. Prétraitement DWI :
   - débruitage (dwidenoise)
   - correction Gibbs (mrdegibbs)
   - correction distorsion/mouvement (dwifslpreproc : topup + eddy)
   - correction de biais (dwibiascorrect ants)
   - upsampling DWI (mrgrid)
3. Génération du masque cerveau (dwi2mask).
4. Modélisation tensorielle (dwi2tensor, tensor2metric : FA, MD, AD, RD).
5. Estimation des fonctions de réponse (dwi2response dhollander).
6. MSMT-CSD (dwi2fod msmt_csd) puis normalisation (mtnormalise).
7. Tractographie iFOD2 (tckgen) et pondération SIFT2 (tcksift2).
8. Génération des figures de QC.

Le script travaille dans un répertoire de travail local dédié (`--work-dir`,
par défaut `~/socosca-work`) : il rapatrie automatiquement le sujet depuis le
stockage centralisé (rclone) avant calcul, puis repousse les dérivés une fois
terminé. Utiliser `--no-pull`/`--no-push` pour travailler entièrement en local
(ex. sur des données déjà présentes), et `--sub <id>` pour ne traiter qu'un
seul sujet. Voir `bash scripts/02_mrtrix_pipeline.sh --help`.

---

## Dépendances

- MRtrix3
- FSL (topup, eddy)
- ANTs
- rclone (rapatriement/publication des données par le pipeline)
- Python 3 + matplotlib (QC)


