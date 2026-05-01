#!/usr/bin/env python3
"""
03_qc_plots.py
Génération des figures de contrôle qualité — Pipeline MRtrix3 / Socosca

Figures générées par sujet (results/plots/sub-XX/) :
  01_noise_map.png        Carte de bruit (dwidenoise) + histogramme
  02_denoise_residual.png Résidu débruitage (b0 + quelques volumes DWI)
  03_brain_mask.png       Masque cerveau superposé au mean b0
  04_dti_metrics.png      FA, MD, AD, RD — coupes axiale / coronale / sagittale
  05_fa_rgb.png           FA colorée par direction V1 (colormap orientationnelle)
  06_response_functions.png Fonctions de réponse WM / GM / CSF (dhollander)
  07_fod_amplitude.png    Amplitude l0 des FOD WM normalisés
  08_eddy_motion.png      Paramètres de mouvement estimés par eddy

Figure récapitulative (results/plots/) :
  summary_FA.png          Coupe axiale FA de chaque sujet (comparaison rapide)

Usage :
  python3 scripts/03_qc_plots.py --subject sub-01 --out_dwi ... --out_plots ...
  python3 scripts/03_qc_plots.py --summary --results_root ... --out_plots ...
"""

import argparse
import os
import sys
from pathlib import Path

import numpy as np
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import matplotlib.gridspec as gridspec
from matplotlib.colors import LinearSegmentedColormap

try:
    import nibabel as nib
except ImportError:
    print("[ERR] nibabel non disponible : pip install nibabel", file=sys.stderr)
    sys.exit(1)

# ---------------------------------------------------------------------------
# Constantes
# ---------------------------------------------------------------------------
DPI = 150
CMAP_GRAY  = "gray"
CMAP_HOT   = "hot"
CMAP_VIRIDIS = "viridis"
CMAP_MASK  = LinearSegmentedColormap.from_list("mask", [(0,0,0,0), (1,0.2,0.2,0.7)])

# Palettes b-values pour les fonctions de réponse
RF_COLORS = {"WM": "#e63946", "GM": "#457b9d", "CSF": "#2a9d8f"}


# ---------------------------------------------------------------------------
# Utilitaires
# ---------------------------------------------------------------------------

def load_vol(path: str) -> tuple[np.ndarray, object]:
    """Charge un volume NIfTI, retourne (data, affine)."""
    img = nib.load(str(path))
    data = np.squeeze(np.asarray(img.dataobj, dtype=np.float32))
    return data, img.affine


def get_slices(vol: np.ndarray, pct: float = 0.5) -> tuple:
    """Retourne les trois coupes (axiale, coronale, sagittale) à pct% du volume."""
    nx, ny, nz = vol.shape[:3]
    ax = int(nx * pct)
    co = int(ny * pct)
    sa = int(nz * pct)
    return vol[ax, :, :], vol[:, co, :], vol[:, :, sa]


def get_multi_slices(vol: np.ndarray, n: int = 9, axis: int = 2) -> list:
    """Retourne n coupes régulièrement espacées selon l'axe donné."""
    size = vol.shape[axis]
    indices = np.linspace(int(size * 0.1), int(size * 0.9), n, dtype=int)
    slices = []
    for i in indices:
        if axis == 2:
            slices.append(np.rot90(vol[:, :, i]))
        elif axis == 1:
            slices.append(np.rot90(vol[:, i, :]))
        else:
            slices.append(np.rot90(vol[i, :, :]))
    return slices


def percentile_clip(data: np.ndarray, lo: float = 1, hi: float = 99) -> np.ndarray:
    """Normalise en clippant aux percentiles lo/hi."""
    lo_v = np.percentile(data[data > 0], lo) if (data > 0).any() else 0
    hi_v = np.percentile(data[data > 0], hi) if (data > 0).any() else 1
    return np.clip((data - lo_v) / max(hi_v - lo_v, 1e-8), 0, 1)


def add_colorbar(ax, im, label: str = ""):
    from mpl_toolkits.axes_grid1 import make_axes_locatable
    div = make_axes_locatable(ax)
    cax = div.append_axes("right", size="4%", pad=0.05)
    plt.colorbar(im, cax=cax, label=label)


def save_fig(fig, path: str, subject_id: str, step: str):
    fig.suptitle(f"{subject_id} — {step}", fontsize=11, y=1.01, weight="bold")
    fig.savefig(path, dpi=DPI, bbox_inches="tight", facecolor="black")
    plt.close(fig)
    print(f"  → {Path(path).name}")


# ---------------------------------------------------------------------------
# Figure 01 : Carte de bruit (dwidenoise)
# ---------------------------------------------------------------------------

def fig_noise_map(noise_map: str, mean_b0: str, subject_id: str, out_dir: str):
    out = os.path.join(out_dir, "01_noise_map.png")
    if not os.path.exists(noise_map):
        return

    noise, _ = load_vol(noise_map)
    b0, _    = load_vol(mean_b0)

    fig = plt.figure(figsize=(16, 6), facecolor="black")
    gs = gridspec.GridSpec(2, 5, figure=fig, hspace=0.1, wspace=0.05)

    # Coupes de la carte de bruit
    slices = get_multi_slices(noise, n=5, axis=2)
    vmax = np.percentile(noise[noise > 0], 99) if (noise > 0).any() else 1
    for i, sl in enumerate(slices):
        ax = fig.add_subplot(gs[0, i])
        ax.imshow(sl.T, cmap=CMAP_HOT, vmin=0, vmax=vmax, origin="lower",
                  aspect="auto")
        ax.axis("off")
        if i == 0:
            ax.set_title("Carte de bruit (σ)", color="white", fontsize=9)

    # Coupes mean b0 (référence)
    slices_b0 = get_multi_slices(b0, n=5, axis=2)
    b0_vmax = np.percentile(b0[b0 > 0], 99) if (b0 > 0).any() else 1
    for i, sl in enumerate(slices_b0):
        ax = fig.add_subplot(gs[1, i])
        ax.imshow(sl.T, cmap=CMAP_GRAY, vmin=0, vmax=b0_vmax, origin="lower",
                  aspect="auto")
        ax.axis("off")
        if i == 0:
            ax.set_title("Mean b0 (référence)", color="white", fontsize=9)

    save_fig(fig, out, subject_id, "Carte de bruit (dwidenoise)")


# ---------------------------------------------------------------------------
# Figure 02 : Résidu débruitage
# ---------------------------------------------------------------------------

def fig_denoise_residual(residual: str, subject_id: str, out_dir: str):
    out = os.path.join(out_dir, "02_denoise_residual.png")
    if not os.path.exists(residual):
        return

    img = nib.load(residual)
    data = np.asarray(img.dataobj, dtype=np.float32)
    if data.ndim == 4:
        # Afficher quelques volumes (b0 + volumes DWI)
        vol_indices = [0, 1, 5, 10, 20, 30]
        vol_indices = [i for i in vol_indices if i < data.shape[3]]
        n_vols = len(vol_indices)
    else:
        vol_indices = [None]
        n_vols = 1

    n_slices = 5
    fig, axes = plt.subplots(n_vols, n_slices,
                             figsize=(3 * n_slices, 2.5 * n_vols),
                             facecolor="black")
    if n_vols == 1:
        axes = axes[np.newaxis, :]

    for row, vi in enumerate(vol_indices):
        vol = data[..., vi] if vi is not None else data
        vabs = np.percentile(np.abs(vol[vol != 0]), 99) if (vol != 0).any() else 1
        slices = get_multi_slices(vol, n=n_slices, axis=2)
        for col, sl in enumerate(slices):
            ax = axes[row, col]
            ax.imshow(sl.T, cmap="RdBu_r", vmin=-vabs, vmax=vabs,
                      origin="lower", aspect="auto")
            ax.axis("off")
        label = f"vol {vi}" if vi is not None else "vol"
        axes[row, 0].set_ylabel(label, color="white", fontsize=8)

    save_fig(fig, out, subject_id, "Résidu débruitage (idéalement : bruit pur, pas de structures)")


# ---------------------------------------------------------------------------
# Figure 03 : Masque cerveau
# ---------------------------------------------------------------------------

def fig_brain_mask(mean_b0: str, mask: str, subject_id: str, out_dir: str):
    out = os.path.join(out_dir, "03_brain_mask.png")
    if not (os.path.exists(mean_b0) and os.path.exists(mask)):
        return

    b0,   _ = load_vol(mean_b0)
    msk,  _ = load_vol(mask)
    msk_bin = (msk > 0.5).astype(float)

    n = 9
    fig, axes = plt.subplots(1, n, figsize=(2.5 * n, 2.5), facecolor="black")
    b0_slices   = get_multi_slices(b0,      n=n, axis=2)
    mask_slices = get_multi_slices(msk_bin, n=n, axis=2)
    b0_vmax = np.percentile(b0[b0 > 0], 99) if (b0 > 0).any() else 1

    for ax, sl_b0, sl_msk in zip(axes, b0_slices, mask_slices):
        ax.imshow(sl_b0.T,  cmap=CMAP_GRAY, vmin=0, vmax=b0_vmax,
                  origin="lower", aspect="auto")
        # Contour du masque en rouge semi-transparent
        ax.contour(sl_msk.T, levels=[0.5], colors=["#ff4444"], linewidths=0.8)
        ax.axis("off")

    save_fig(fig, out, subject_id, "Masque cerveau (contour rouge) sur mean b0")


# ---------------------------------------------------------------------------
# Figure 04 : Métriques DTI (FA, MD, AD, RD)
# ---------------------------------------------------------------------------

def fig_dti_metrics(fa: str, md: str, ad: str, rd: str,
                    mask: str, subject_id: str, out_dir: str):
    out = os.path.join(out_dir, "04_dti_metrics.png")
    metrics = {"FA": (fa, CMAP_GRAY, 0, 1),
               "MD": (md, CMAP_VIRIDIS, 0, 0.003),
               "AD": (ad, CMAP_VIRIDIS, 0, 0.004),
               "RD": (rd, CMAP_VIRIDIS, 0, 0.003)}
    # Filtrer les métriques disponibles
    metrics = {k: v for k, v in metrics.items() if os.path.exists(v[0])}
    if not metrics:
        return

    if os.path.exists(mask):
        msk, _ = load_vol(mask)
        msk_bin = (msk > 0.5)
    else:
        msk_bin = None

    n_rows = len(metrics)
    n_cols = 7  # coupes axiales
    fig, axes = plt.subplots(n_rows, n_cols,
                             figsize=(2.2 * n_cols, 2.2 * n_rows),
                             facecolor="black")
    if n_rows == 1:
        axes = axes[np.newaxis, :]

    for row, (name, (path, cmap, vmin, vmax)) in enumerate(metrics.items()):
        data, _ = load_vol(path)
        if msk_bin is not None:
            data_masked = data.copy()
            data_masked[~msk_bin] = 0
        else:
            data_masked = data

        slices = get_multi_slices(data_masked, n=n_cols, axis=2)
        for col, sl in enumerate(slices):
            ax = axes[row, col]
            im = ax.imshow(sl.T, cmap=cmap, vmin=vmin, vmax=vmax,
                           origin="lower", aspect="auto", interpolation="nearest")
            ax.axis("off")
        axes[row, 0].set_ylabel(name, color="white", fontsize=10, fontweight="bold")

        # Colorbar sur la dernière colonne
        from mpl_toolkits.axes_grid1 import make_axes_locatable
        div = make_axes_locatable(axes[row, -1])
        cax = div.append_axes("right", size="8%", pad=0.05)
        cb = fig.colorbar(im, cax=cax)
        cb.ax.tick_params(colors="white", labelsize=7)

    save_fig(fig, out, subject_id, "Métriques DTI (b=1000)")


# ---------------------------------------------------------------------------
# Figure 05 : FA-RGB (colormap orientationnelle)
# ---------------------------------------------------------------------------

def fig_fa_rgb(fa: str, v1: str, mask: str, subject_id: str, out_dir: str):
    out = os.path.join(out_dir, "05_fa_rgb.png")
    if not (os.path.exists(fa) and os.path.exists(v1)):
        return

    fa_data, _ = load_vol(fa)
    v1_data, _ = load_vol(v1)   # shape (x, y, z, 3)
    if v1_data.ndim < 4 or v1_data.shape[3] < 3:
        return

    if os.path.exists(mask):
        msk, _ = load_vol(mask)
        msk_bin = (msk > 0.5)
    else:
        msk_bin = np.ones_like(fa_data, dtype=bool)

    # RGB = |eigenvector| * FA
    rgb = np.abs(v1_data[..., :3]) * fa_data[..., np.newaxis]
    rgb[~msk_bin] = 0
    # Normaliser entre 0 et 1
    rgb = np.clip(rgb, 0, 1)

    n = 9
    fig, axes = plt.subplots(1, n, figsize=(2.5 * n, 2.5), facecolor="black")
    nz = rgb.shape[2]
    indices = np.linspace(int(nz * 0.1), int(nz * 0.9), n, dtype=int)
    for ax, i in zip(axes, indices):
        sl = np.rot90(rgb[:, :, i, :])
        ax.imshow(sl, origin="lower", aspect="auto", interpolation="nearest")
        ax.axis("off")

    save_fig(fig, out, subject_id, "FA-RGB (couleur = direction principale V1)")


# ---------------------------------------------------------------------------
# Figure 06 : Fonctions de réponse
# ---------------------------------------------------------------------------

def fig_response_functions(rf_wm: str, rf_gm: str, rf_csf: str,
                            subject_id: str, out_dir: str):
    out = os.path.join(out_dir, "06_response_functions.png")

    fig, axes = plt.subplots(1, 3, figsize=(12, 4), facecolor="white")
    fig.subplots_adjust(wspace=0.35)

    labels = {"WM": rf_wm, "GM": rf_gm, "CSF": rf_csf}
    for ax, (name, path) in zip(axes, labels.items()):
        ax.set_title(f"Réponse {name}", fontsize=11, fontweight="bold")
        ax.set_xlabel("b-value (s/mm²)", fontsize=9)
        ax.set_ylabel("Signal (l=0)", fontsize=9)
        ax.tick_params(labelsize=8)
        ax.grid(True, alpha=0.3)
        ax.set_facecolor("#f8f9fa")

        if not os.path.exists(path):
            ax.text(0.5, 0.5, "Non disponible", ha="center", va="center",
                    transform=ax.transAxes, color="gray")
            continue

        try:
            # Format MRtrix : 1re ligne = nshells nbvalues, puis une ligne par shell
            lines = [l.strip() for l in open(path) if l.strip()]
            header = list(map(int, lines[0].split()))
            nshells = header[0]
            shell_data = []
            for i in range(1, 1 + nshells):
                vals = list(map(float, lines[i].split()))
                shell_data.append(vals)

            # Les b-values sont dans le header (dernière ligne ou lus depuis les RF)
            # Pour dhollander, chercher la ligne des b-values (après les RF)
            bvals_line_idx = 1 + nshells
            if bvals_line_idx < len(lines):
                bvals = list(map(float, lines[bvals_line_idx].split()))
            else:
                bvals = list(range(nshells))

            color = RF_COLORS.get(name, "#333333")
            for bv, coeffs in zip(bvals, shell_data):
                # Tracer uniquement le coefficient l=0
                l0 = coeffs[0] if coeffs else 0
                ax.bar(bv, l0, width=max(50, bv * 0.05),
                       color=color, alpha=0.7, label=f"b={int(bv)}")

            ax.legend(fontsize=8)

        except Exception as e:
            ax.text(0.5, 0.5, f"Erreur: {e}", ha="center", va="center",
                    transform=ax.transAxes, color="red", fontsize=8)

    save_fig(fig, out, subject_id, "Fonctions de réponse dhollander (WM / GM / CSF)")


# ---------------------------------------------------------------------------
# Figure 07 : Amplitude l0 des FOD WM
# ---------------------------------------------------------------------------

def fig_fod_amplitude(fod_amp: str, mask: str, subject_id: str, out_dir: str):
    out = os.path.join(out_dir, "07_fod_amplitude.png")
    if not os.path.exists(fod_amp):
        return

    amp, _  = load_vol(fod_amp)
    if os.path.exists(mask):
        msk, _ = load_vol(mask)
        amp[msk < 0.5] = 0

    n = 9
    fig, axes = plt.subplots(1, n, figsize=(2.5 * n, 2.5), facecolor="black")
    slices = get_multi_slices(amp, n=n, axis=2)
    vmax = np.percentile(amp[amp > 0], 99) if (amp > 0).any() else 1

    for ax, sl in zip(axes, slices):
        ax.imshow(sl.T, cmap=CMAP_VIRIDIS, vmin=0, vmax=vmax,
                  origin="lower", aspect="auto", interpolation="nearest")
        ax.axis("off")

    save_fig(fig, out, subject_id,
             "Amplitude l0 des FOD WM normalisés (MSMT-CSD)")


# ---------------------------------------------------------------------------
# Figure 08 : Paramètres de mouvement eddy
# ---------------------------------------------------------------------------

def fig_eddy_motion(eddy_dir: str, subject_id: str, out_dir: str):
    out = os.path.join(out_dir, "08_eddy_motion.png")

    # Chercher les fichiers de mouvement eddy
    motion_file = None
    for candidate in [
        os.path.join(eddy_dir, "eddy_corrected.eddy_parameters"),
        os.path.join(eddy_dir, "eddy_corrected.eddy_movement_rms"),
    ]:
        if os.path.exists(candidate):
            motion_file = candidate
            break

    # Chercher dans les sous-dossiers tmp si eddy_dir vide
    if motion_file is None:
        for root, dirs, files in os.walk(eddy_dir):
            for f in files:
                if "eddy_parameters" in f or "movement_rms" in f:
                    motion_file = os.path.join(root, f)
                    break
            if motion_file:
                break

    if motion_file is None:
        fig, ax = plt.subplots(figsize=(8, 3), facecolor="white")
        ax.text(0.5, 0.5, "Fichiers eddy QC non trouvés\n"
                "(vérifier -eddyqc_all dans dwifslpreproc)",
                ha="center", va="center", transform=ax.transAxes,
                fontsize=11, color="gray")
        ax.axis("off")
        save_fig(fig, out, subject_id, "Mouvement eddy")
        return

    try:
        params = np.loadtxt(motion_file)
    except Exception:
        return

    is_params = params.ndim == 2 and params.shape[1] >= 6

    fig, axes = plt.subplots(2, 1, figsize=(12, 6), facecolor="white",
                             sharex=True)

    vols = np.arange(len(params))

    if is_params:
        # Colonnes 0-2 : translations (mm), 3-5 : rotations (rad→deg)
        trans = params[:, :3]
        rots  = np.degrees(params[:, 3:6]) if params.shape[1] >= 6 else params[:, 3:6]

        for i, (label, color) in enumerate(
                zip(["x", "y", "z"], ["#e63946", "#457b9d", "#2a9d8f"])):
            axes[0].plot(vols, trans[:, i], label=f"T{label}", color=color, lw=1)
            axes[1].plot(vols, rots[:, i],  label=f"R{label}", color=color,
                         lw=1, linestyle="--")

        axes[0].set_ylabel("Translation (mm)", fontsize=9)
        axes[1].set_ylabel("Rotation (°)", fontsize=9)
    else:
        axes[0].plot(vols, params[:, 0], color="#e63946", lw=1,
                     label="RMS mouvement (vol)")
        axes[0].set_ylabel("RMS déplacement (mm)", fontsize=9)
        axes[1].set_visible(False)

    for ax in axes:
        ax.set_facecolor("#f8f9fa")
        ax.grid(True, alpha=0.3)
        ax.legend(fontsize=8)
        ax.tick_params(labelsize=8)

    axes[-1].set_xlabel("Volume DWI", fontsize=9)
    save_fig(fig, out, subject_id, "Paramètres de mouvement eddy")


# ---------------------------------------------------------------------------
# Figure récapitulative multi-sujets
# ---------------------------------------------------------------------------

def fig_summary(results_root: str, out_plots: str):
    out = os.path.join(out_plots, "summary_FA.png")

    subjects = sorted(Path(results_root).glob("sub-*"))
    if not subjects:
        return

    fa_files = []
    for sub in subjects:
        fa_pattern = list(sub.glob("dwi/*_model-DTI_param-FA_dti.nii.gz"))
        if fa_pattern:
            fa_files.append((sub.name, fa_pattern[0]))

    if not fa_files:
        return

    n_subs = len(fa_files)
    n_slices = 5
    fig, axes = plt.subplots(n_subs, n_slices,
                             figsize=(2.5 * n_slices, 2.2 * n_subs),
                             facecolor="black")
    if n_subs == 1:
        axes = axes[np.newaxis, :]

    for row, (sub_id, fa_path) in enumerate(fa_files):
        fa, _ = load_vol(str(fa_path))
        slices = get_multi_slices(fa, n=n_slices, axis=2)
        for col, sl in enumerate(slices):
            ax = axes[row, col]
            ax.imshow(sl.T, cmap=CMAP_GRAY, vmin=0, vmax=1,
                      origin="lower", aspect="auto", interpolation="nearest")
            ax.axis("off")
        axes[row, 0].set_ylabel(sub_id, color="white", fontsize=9,
                                 fontweight="bold")

    fig.suptitle("FA — Comparaison inter-sujets", fontsize=13, y=1.01,
                 weight="bold", color="white")
    fig.savefig(out, dpi=DPI, bbox_inches="tight", facecolor="black")
    plt.close(fig)
    print(f"  → summary_FA.png ({n_subs} sujets)")


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(description="Figures QC pipeline MRtrix3 Socosca")

    # Mode sujet unique
    parser.add_argument("--subject",    type=str, default="")
    parser.add_argument("--out_dwi",    type=str, default="")
    parser.add_argument("--out_plots",  type=str, default="")
    parser.add_argument("--mean_b0",    type=str, default="")
    parser.add_argument("--mask",       type=str, default="")
    parser.add_argument("--noise_map",  type=str, default="")
    parser.add_argument("--residual",   type=str, default="")
    parser.add_argument("--fa",         type=str, default="")
    parser.add_argument("--md",         type=str, default="")
    parser.add_argument("--ad",         type=str, default="")
    parser.add_argument("--rd",         type=str, default="")
    parser.add_argument("--v1",         type=str, default="")
    parser.add_argument("--fod_amp",    type=str, default="")
    parser.add_argument("--rf_wm",      type=str, default="")
    parser.add_argument("--rf_gm",      type=str, default="")
    parser.add_argument("--rf_csf",     type=str, default="")
    parser.add_argument("--eddy_dir",   type=str, default="")

    # Mode récapitulatif
    parser.add_argument("--summary",       action="store_true")
    parser.add_argument("--results_root",  type=str, default="")

    args = parser.parse_args()

    if args.summary:
        if not args.results_root or not args.out_plots:
            parser.error("--summary requiert --results_root et --out_plots")
        print(f"\n[QC summary] {args.results_root}")
        os.makedirs(args.out_plots, exist_ok=True)
        fig_summary(args.results_root, args.out_plots)
        return

    # Mode sujet unique
    if not args.subject or not args.out_plots:
        parser.error("--subject et --out_plots requis")

    os.makedirs(args.out_plots, exist_ok=True)
    print(f"\n[QC] {args.subject}  →  {args.out_plots}")

    # Reconstruire les chemins AD/RD/V1 si non fournis (inférence depuis out_dwi)
    def infer(arg, pattern):
        if arg:
            return arg
        if args.out_dwi:
            candidates = list(Path(args.out_dwi).glob(pattern))
            return str(candidates[0]) if candidates else ""
        return ""

    ad_path  = infer(args.ad,  f"*_param-AD_dti.nii.gz")
    rd_path  = infer(args.rd,  f"*_param-RD_dti.nii.gz")
    v1_path  = infer(args.v1,  f"*_param-V1_dti.nii.gz")

    fig_noise_map(args.noise_map, args.mean_b0, args.subject, args.out_plots)
    fig_denoise_residual(args.residual, args.subject, args.out_plots)
    fig_brain_mask(args.mean_b0, args.mask, args.subject, args.out_plots)
    fig_dti_metrics(args.fa, args.md, ad_path, rd_path,
                    args.mask, args.subject, args.out_plots)
    fig_fa_rgb(args.fa, v1_path, args.mask, args.subject, args.out_plots)
    fig_response_functions(args.rf_wm, args.rf_gm, args.rf_csf,
                           args.subject, args.out_plots)
    fig_fod_amplitude(args.fod_amp, args.mask, args.subject, args.out_plots)
    fig_eddy_motion(args.eddy_dir, args.subject, args.out_plots)

    print(f"  [OK] Figures QC terminées : {args.out_plots}")


if __name__ == "__main__":
    main()
