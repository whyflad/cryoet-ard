# Automated Cryo-ET Alignment, Reconstruction, and Denoising Pipeline

An **automated, integrated, command-line, Slurm-based** cryo-electron tomography workflow for tilt-series alignment, tomogram reconstruction, and denoising that connects [AreTomo3](https://github.com/czimaginginstitute/AreTomo3), [MissAlignment](https://github.com/warpem/miss-alignment), [WarpTools](https://github.com/warpem/warp), and [IsoNet2](https://github.com/IsoNet-cryoET/IsoNet2). The repository contains wrapper scripts and documentation, **not** any of those third-party programs or sample acquisition data.

> **Status:** A portable configuration template is provided. The converted scripts have **not** been validated by a complete GPU processing run on another cluster. A multi-GPU IsoNet2 installation patch is required (details below); the original source patch is not included in this archive. Treat this as a configurable research workflow rather than a guaranteed plug-and-play installation.

## Workflow

```text
Raw tilt-series EER movies + per-tilt .eer.mdoc sidecars
                         |
                         v
               make_aretomo3_mdoc.py
                         |
                         v
       AreTomo3 (motion correction, initial alignment)
                         |
           full / EVN / ODD tilt stacks
                         |
                         v
          WarpTools preparation + MissAlignment
                         |
              refined Warp project
                         |
                         v
                 WarpTools reconstruction
                   + CTF estimation
                         |
            full / EVN / ODD tomograms
                         |
                         v
             IsoNet2 refine / predict
               / mask / refine / predict
                         |
                         v
               Corrected tomograms
```

You must supply your own pixel size, dose, volume dimensions, tilt axis, and gain reference in `config.sh`. The workflow assumes input `.eer` movies paired with `.eer.mdoc` sidecars in each tilt-series directory; other formats are not supported directly.

## Repository files

```text
cryoet-ard/
├── README.md
├── LICENSE
├── config.example.sh                  # public template only
├── pipeline.sh                        # pipeline controller (run on login node)
├── make_aretomo3_mdoc.py              # input MDOC merger
├── run_aretomo3.sbatch
├── run_missalignment.sbatch
├── run_warp_reconstruction.sbatch
└── run_isonet2.sbatch
```

## Requirements

- Linux HPC system with `sbatch`, `bash`, Python 3, NVIDIA CUDA GPUs, and appropriate GPU drivers.
- Built [AreTomo3](https://github.com/czimaginginstitute/AreTomo3) executable.
- [WarpTools](https://github.com/warpem/warp) installed in a separate Conda environment.
- [MissAlignment](https://github.com/warpem/miss-alignment) installed in a separate Conda environment with `torch` and `warpylib`.
- [IsoNet2](https://github.com/IsoNet-cryoET/IsoNet2) installed in a separate Conda environment with the required **DDP dynamic-port patch** checked by `run_isonet2.sbatch` (the patch itself is not included).
- Python packages `numpy` and `mrcfile` in the relevant environments as required by the stage scripts.

**Exact tested tool versions were not supplied with the source scripts.** Do not assume that the latest upstream package versions are compatible with this pipeline. Record the revisions tested locally.

## Input files

```text
/raw/project/
├── gain_reference.gain
├── tiltseries_001/
│   ├── exposure_0001.eer
│   ├── exposure_0001.eer.mdoc
│   ├── exposure_0002.eer
│   └── exposure_0002.eer.mdoc
└── tiltseries_002/
    └── ...
```

These are **invented filenames**, not user data. Each `.eer` must have exactly one corresponding `.eer.mdoc`. The merger checks tilt angles and optional filename-encoded angles and overwrites `<tiltseries_name>.mdoc` **inside the source tilt-series directory**. Back up any pre-existing merged MDOC before running. Dataset directory names must be simple basenames (letters, numbers, underscores, hyphens, dots).

## Quick start

Install the third-party programs separately first. Clone or unpack the repository, then create a **private configuration outside the GitHub checkout**:

```bash
mkdir -p "$HOME/cryoet-pipeline-config"
cp config.example.sh "$HOME/cryoet-pipeline-config/config.sh"
# Edit this private config.sh: data, software paths, acquisition metadata and Slurm options.
```

This repository does not include a `.gitignore`. **Do not add your private `config.sh`, raw data, logs, or processing outputs to Git.** Keeping the configuration outside the repository reduces the risk of accidentally committing real paths and dataset identifiers.

Set `RUN_DIR` to a **dedicated processing directory outside this repository**. Do not use your raw-data directory as `RUN_DIR`. Its generated subdirectories may be deleted during reruns.

Then run a no-submit preview from a **login/submission node**:

```bash
bash pipeline.sh --config="$HOME/cryoet-pipeline-config/config.sh" --dry-run
```

The dry-run prints resolved paths and planned `sbatch` commands. It does not run the actual stages or verify application compatibility. It does not create output directories. When configuration, prerequisites and your dataset have been checked, run:

```bash
bash pipeline.sh --config="$HOME/cryoet-pipeline-config/config.sh"
```

To use another configuration, change the `--config` path.

The controller submits a stage with `sbatch --wait`, checks that stage's required outputs, and continues only when it finishes successfully. The controller itself runs on the submission node and does not consume a GPU allocation. All stage resource requests are `SLURM_*_ARGS` arrays in `config.sh`; adapt them for your site. The supplied four-GPU settings are example allocations from the source workflow, not hardware requirements for all configurations.

## Configuration

The editable `config.sh` separates:

| Category           | Examples                                                                                                   |
| ------------------ | ---------------------------------------------------------------------------------------------------------- |
| Input and output   | `DATA_ROOT`, `DATASETS`, `RUN_DIR`, `GAIN_FILE`                                                            |
| Installed software | `ARETOMO3`, `WARPTOOLS_ENV`, `MISSALIGN_ENV`, `ISONET2_ENV`                                                |
| Cluster resources  | `SLURM_COMMON_ARGS`, `SLURM_ARETOMO_ARGS`, `SLURM_MISSALIGN_ARGS`, `SLURM_WARP_ARGS`, `SLURM_ISONET2_ARGS` |
| Acquisition values | `PIX_SIZE`, `KV`, `CS`, `DOSE_PER_TILT`, `EER_FRAMES_PER_TILT`, `TILT_AXIS`, `VOLZ`, `TOMO_DIMENSIONS`     |
| Processing         | AreTomo3 tuning, MissAlignment schedule, Warp CTF/reconstruction, IsoNet2 epochs and masks                 |
| Reruns             | `RUN_ARETOMO3`, `RUN_MISSALIGNMENT`, `RUN_WARP_RECONSTRUCTION`, `RUN_ISONET2`                              |

`FM_DOSE`, IsoNet2 microscope parameters and target pixel size are derived from the corresponding input/configuration fields to reduce inconsistencies. To adjust the GPU numbering or CUDA setup, edit `ARETOMO_GPU_ID`, `MISS_TRAINING_DEVICES`, `MISS_RECONSTRUCTION_DEVICES`, `ISONET2_GPU_ID`, `CLUSTER_INIT` or `ARETOMO_CUDA_MODULE` as appropriate.

## Run output

```text
/private/runs/run_001/
├── out/                          # AreTomo3 outputs
├── temp/                         # AreTomo3 scratch
├── input_missalignment/
├── output_missalignment/
│   └── warp_project/
├── input_warp_reconstruction/
├── output_warp_reconstruction/
│   ├── ctf/
│   ├── tomograms/reconstruction/
│   ├── tomograms_EVN/reconstruction/
│   └── tomograms_ODD/reconstruction/
├── input_isonet2/
├── output_isonet2/
└── log/
```

The stage scripts retain **deliberate rebuild operations**. Specifically, MissAlignment can replace its generated Warp project, Warp reconstruction replaces selected reconstructed output directories, and IsoNet2 may replace selected stage outputs. Never point `RUN_DIR` at data you need to preserve. If resuming, check stage switches and `REBUILD_WARP_PROJECT` and `ISONET2_CLEAN_STAGE_OUTPUTS` first. The controller cannot infer whether the existing outputs belong to the same datasets.

## Limitations

- Slurm only. Other schedulers such as PBS and LSF are not supported.
- Requires same-node GPU allocations for multi-GPU MissAlignment and IsoNet2 workflows.
- A preinstalled patched IsoNet2 is required; the patch itself is not recoverable from these wrapper scripts.
- No complete end-to-end validation against an archived cryo-ET dataset has been performed for this portable release.
- The `.eer.mdoc` merger assumes a per-tilt sidecar format; user acquisition software may export metadata differently.
- The original input/output stage layout is retained, including a merged MDOC written to raw input and some generated temporary symlinks.

## Related open-source projects

- [Cell Architecture Lab — Engel Warp Pipeline](https://github.com/CellArchLab/Engel_Warp_Pipeline)
- [Cell Architecture Lab — cryoet-scripts](https://github.com/CellArchLab/cryoet-scripts)
- [TomoGuide](https://tomoguide.github.io/)
- [AreTomo3](https://github.com/czimaginginstitute/AreTomo3)
- [Warp](https://github.com/warpem/warp)
- [MissAlignment](https://github.com/warpem/miss-alignment)
- [IsoNet2](https://github.com/IsoNet-cryoET/IsoNet2)

Please cite the appropriate upstream research articles and software repositories when using those tools. The MIT license in this package covers **only the original orchestration scripts and accompanying documentation**, not the separately installed third-party programs. Review license ownership and attribution before distributing publicly.
