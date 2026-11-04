#!/usr/bin/env python3

import argparse
import math
import re
import sys
from pathlib import Path

SECTION_RE = re.compile(r'^\[(FrameSet|ZValue)\s*=\s*[-+]?\d+\]\s*$')
KV_RE = re.compile(r'^(\s*)([^=\s][^=]*?)(\s*=\s*)(.*?)(\s*)$')
# Optional filename convention: <anything>_<acquisition-index>_<tilt-angle>.eer
FILENAME_ANGLE_RE = re.compile(
    r'_(?P<index>\d+)_(?P<angle>[+-]?(?:\d+(?:\.\d*)?|\.\d+))\.eer$',
    re.IGNORECASE,
)


def natural_key(path: Path):
    return [int(x) if x.isdigit() else x for x in re.split(r'(\d+)', path.name)]


def split_mdoc(path: Path):
    lines = path.read_text(errors="replace").splitlines()

    header = []
    sections = []
    current = None

    for line in lines:
        if SECTION_RE.match(line.strip()):
            if current is not None:
                sections.append(current)
            current = [line]
        else:
            if current is None:
                header.append(line)
            else:
                current.append(line)

    if current is not None:
        sections.append(current)

    return header, sections


def get_value(section, key):
    key_lower = key.lower()
    for line in section:
        match = KV_RE.match(line)
        if match and match.group(2).strip().lower() == key_lower:
            return match.group(4).strip()
    return None


def set_or_insert_normal(section, key, value):
    key_lower = key.lower()
    out = []
    done = False

    for line in section:
        match = KV_RE.match(line)
        if match and match.group(2).strip().lower() == key_lower:
            out.append(f"{key} = {value}")
            done = True
        else:
            out.append(line)

    if not done:
        out.append(f"{key} = {value}")

    return out


def set_or_insert_no_space_after_equal(section, key, value):
    key_lower = key.lower()
    out = []
    done = False

    for line in section:
        match = KV_RE.match(line)
        if match and match.group(2).strip().lower() == key_lower:
            out.append(f"{key}={value}")
            done = True
        else:
            out.append(line)

    if not done:
        out.append(f"{key}={value}")

    return out


def verify_eer_sidecar_pairs(dataset_dir: Path):
    eer_files = sorted(dataset_dir.glob("*.eer"), key=natural_key)
    sidecars = sorted(dataset_dir.glob("*.eer.mdoc"), key=natural_key)

    eer_names = {path.name for path in eer_files}
    sidecar_eer_names = {path.name[:-5] for path in sidecars}

    missing_sidecars = sorted(eer_names - sidecar_eer_names)
    missing_eers = sorted(sidecar_eer_names - eer_names)

    if missing_sidecars or missing_eers:
        print("ERROR: EER/sidecar pairing is incomplete.", file=sys.stderr)
        if missing_sidecars:
            print("EER files missing matching .eer.mdoc sidecars:", file=sys.stderr)
            for name in missing_sidecars:
                print(f"  {name}", file=sys.stderr)
        if missing_eers:
            print("Sidecars missing matching EER files:", file=sys.stderr)
            for name in missing_eers:
                print(f"  {name}.mdoc", file=sys.stderr)
        raise SystemExit(1)

    if not sidecars:
        raise SystemExit(f"ERROR: no per-tilt *.eer.mdoc files found in {dataset_dir}")

    print(f"Verified complete EER/sidecar pairs: {len(sidecars)}")
    return sidecars


def filename_angle(eer_name: str):
    match = FILENAME_ANGLE_RE.search(eer_name)
    if match is None:
        return None
    return float(match.group("angle"))


def main():
    parser = argparse.ArgumentParser(
        description="Merge per-tilt *.eer.mdoc files into one AreTomo3 tilt-series .mdoc."
    )
    parser.add_argument("--dataset-dir", required=True)
    parser.add_argument("--dataset-name", required=True)
    parser.add_argument("--dose-per-tilt", required=True)
    parser.add_argument(
        "--angle-tolerance",
        type=float,
        default=0.05,
        help=(
            "Maximum allowed difference in degrees between TiltAngle metadata "
            "and an angle encoded at the end of an EER filename. Filenames "
            "without the optional _INDEX_ANGLE.eer pattern are not rejected."
        ),
    )
    args = parser.parse_args()

    dataset_dir = Path(args.dataset_dir).resolve()
    dataset_name = args.dataset_name
    dose_per_tilt = str(args.dose_per_tilt)
    angle_tolerance = float(args.angle_tolerance)

    if not dataset_dir.is_dir():
        sys.exit(f"ERROR: dataset folder does not exist: {dataset_dir}")
    if not math.isfinite(angle_tolerance) or angle_tolerance < 0:
        sys.exit(f"ERROR: invalid --angle-tolerance: {angle_tolerance}")

    per_tilt_mdocs = verify_eer_sidecar_pairs(dataset_dir)
    merged_mdoc = dataset_dir / f"{dataset_name}.mdoc"

    out_lines = []
    first_header_written = False
    filename_angles_checked = 0
    filename_angles_skipped = 0

    for z, mdoc_path in enumerate(per_tilt_mdocs):
        header, sections = split_mdoc(mdoc_path)

        if len(sections) != 1:
            sys.exit(
                f"ERROR: expected exactly one section in {mdoc_path}, "
                f"but found {len(sections)} sections."
            )

        section = sections[0]

        tilt_angle_text = get_value(section, "TiltAngle")
        if tilt_angle_text is None:
            sys.exit(f"ERROR: no TiltAngle found in {mdoc_path}")
        try:
            tilt_angle = float(tilt_angle_text)
        except ValueError as exc:
            raise SystemExit(
                f"ERROR: invalid TiltAngle in {mdoc_path}: {tilt_angle_text}"
            ) from exc
        if not math.isfinite(tilt_angle):
            sys.exit(f"ERROR: non-finite TiltAngle in {mdoc_path}: {tilt_angle_text}")

        eer_name = mdoc_path.name[:-5]
        eer_path = dataset_dir / eer_name

        if not eer_path.is_file():
            sys.exit(f"ERROR: matching EER file not found for {mdoc_path.name}: {eer_path}")

        encoded_angle = filename_angle(eer_name)
        if encoded_angle is None:
            filename_angles_skipped += 1
        else:
            filename_angles_checked += 1
            difference = abs(encoded_angle - tilt_angle)
            if difference > angle_tolerance:
                sys.exit(
                    f"ERROR: filename angle and TiltAngle disagree for {mdoc_path.name}: "
                    f"filename={encoded_angle:.6f} deg, metadata={tilt_angle:.6f} deg, "
                    f"difference={difference:.6f} deg, tolerance={angle_tolerance:.6f} deg"
                )

        if not first_header_written:
            while header and header[-1].strip() == "":
                header.pop()

            out_lines.extend(header)
            if out_lines:
                out_lines.append("")

            first_header_written = True

        section[0] = f"[ZValue = {z}]"
        section = set_or_insert_no_space_after_equal(section, "SubFramePath", eer_name)
        section = set_or_insert_normal(section, "ExposureDose", dose_per_tilt)

        while section and section[-1].strip() == "":
            section.pop()

        out_lines.extend(section)
        out_lines.append("")

    merged_mdoc.write_text("\n".join(out_lines).rstrip() + "\n")

    print(f"Wrote merged AreTomo3 mdoc: {merged_mdoc}")
    print(f"Number of per-tilt mdocs merged: {len(per_tilt_mdocs)}")
    print(f"Expected ZValue sections: {len(per_tilt_mdocs)}")
    print(f"Filename angles checked: {filename_angles_checked}")
    print(f"Filename angles skipped (pattern absent): {filename_angles_skipped}")


if __name__ == "__main__":
    main()
