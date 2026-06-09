# Projet Socosca - Traitement IRM diffusion

## Description du projet

Pipeline de traitement automatisé pour données IRM anatomiques (T1w) et de diffusion (DWI).
Le projet s'appuie principalement sur MRtrix3, FSL et ANTs.

Objectif : produire des dérivés de diffusion (métriques DTI, FOD, tractographie) et des sorties de contrôle qualité de manière reproductible.

Note : les chemins locaux sont configurés dans `config/machine.sh` et ne sont pas figés dans cette documentation.

---

## Structure des données d'entrée

Organisation attendue par sujet :

```text
sub-XX/
|-- anat/
|   |-- T1.nii.gz           # Image anatomique T1w
|   `-- T1.json             # Métadonnées associées
`-- dwi/
    |-- dwi_b1000.nii[.gz]  # DWI + fichiers .bval/.bvec/.json
    |-- dwi_b2000.nii[.gz]  # DWI + fichiers .bval/.bvec/.json
    |-- dwi_AP.nii[.gz]     # b0 AP (correction de distorsion)
    |-- dwi_AP.json
    |-- dwi_PA.nii[.gz]     # b0 PA (correction de distorsion)
    `-- dwi_PA.json
```

---

## Structure du projet

```text
scripts/
|-- 00_data_overview.sh       # Inspection des données (dimensions, volumes, b-values)
|-- 01_zip_nii.sh             # Compression NIfTI (.nii -> .nii.gz)
|-- 02_mrtrix_pipeline.sh     # Pipeline diffusion principal
|-- 03_qc_plots.py            # Figures de QC
|-- 04_siam_segmentation.sh
|-- 05_freesurfer_segmentation.sh
|-- 06_tractseg_cerebellum.sh
`-- 07_scilpy_cerebellum.sh

results/
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

---

## Dépendances

- MRtrix3
- FSL (topup, eddy)
- ANTs
- Python 3 + matplotlib (QC)

---

## Confidentialité

- Ne pas versionner de données brutes, dérivées sensibles ou informations d'infrastructure.
- Éviter d'exposer des chemins personnels, adresses IP, hôtes ou identifiants dans les scripts et la documentation.
- Conserver uniquement des exemples génériques et des noms de sujets pseudonymisés (ex. `sub-01`).
