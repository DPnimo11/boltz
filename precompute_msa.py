"""Pre-compute one ColabFold MSA per target, then inject the MSA path into every
yaml so boltz skips the (rate-limited, redundant) per-ligand MSA step.

Each target's protein sequence is identical across all its ligands, so we only
need one MSA per target. Generating sequentially avoids hammering the colabfold
rate limiter with 4 concurrent boltz processes.

Outputs:
  Boltz_output/_msa/<TARGET>.csv         — boltz-formatted MSA, one per target
  Boltz_output/_fixed_inputs/<TARGET>/*.yaml — each yaml gets `msa: <abs path>`
"""
import os, sys, glob, yaml, time
from pathlib import Path

ROOT = Path("/work/jwang/boltz2")
FIXED_DIR = ROOT / "Boltz_output" / "_fixed_inputs"
MSA_DIR = ROOT / "Boltz_output" / "_msa"
MSA_DIR.mkdir(parents=True, exist_ok=True)

# Import boltz's MSA helper. The package at /work/jwang/boltz2/boltz/src/ is on
# sys.path because boltz is installed in editable mode in ~/.local.
from boltz.main import compute_msa  # noqa: E402

MSA_SERVER_URL = "https://api.colabfold.com"
MSA_PAIRING_STRATEGY = "greedy"


def get_target_sequence(target_dir: Path) -> str:
    """Read the first yaml in target_dir and return its protein sequence."""
    yamls = sorted(target_dir.glob("*.yaml"))
    if not yamls:
        raise RuntimeError(f"No yamls in {target_dir}")
    with open(yamls[0]) as f:
        data = yaml.safe_load(f)
    for s in data["sequences"]:
        if "protein" in s:
            return s["protein"]["sequence"].strip()
    raise RuntimeError(f"No protein entry in {yamls[0]}")


def inject_msa(target_dir: Path, msa_path: Path):
    """Add `msa: <path>` to the protein entry of every yaml in target_dir."""
    n = 0
    for y in sorted(target_dir.glob("*.yaml")):
        with open(y) as f:
            data = yaml.safe_load(f)
        changed = False
        for s in data["sequences"]:
            if "protein" in s and s["protein"].get("msa") != str(msa_path):
                s["protein"]["msa"] = str(msa_path)
                changed = True
        if changed:
            with open(y, "w") as f:
                yaml.safe_dump(data, f, sort_keys=False)
        n += 1
    return n


def main():
    targets = sorted([d.name for d in FIXED_DIR.iterdir() if d.is_dir() and not d.name.startswith("_")])
    print(f"Targets: {targets}")
    print(f"MSA output dir: {MSA_DIR}")
    print()

    only = sys.argv[1:] if len(sys.argv) > 1 else None
    if only:
        targets = [t for t in targets if t in only]
        print(f"(filtered to: {targets})")

    for i, t in enumerate(targets, 1):
        td = FIXED_DIR / t
        out_csv = MSA_DIR / f"{t}.csv"
        if out_csv.exists() and out_csv.stat().st_size > 0:
            print(f"[{i}/{len(targets)}] {t}: MSA exists ({out_csv.stat().st_size} bytes), skipping generation")
        else:
            seq = get_target_sequence(td)
            print(f"[{i}/{len(targets)}] {t}: generating MSA for {len(seq)}-aa protein...")
            t0 = time.time()
            compute_msa(
                data={t: seq},   # key -> filename stem (will write <MSA_DIR>/<key>.csv)
                target_id=t,
                msa_dir=MSA_DIR,
                msa_server_url=MSA_SERVER_URL,
                msa_pairing_strategy=MSA_PAIRING_STRATEGY,
            )
            dt = time.time() - t0
            sz = out_csv.stat().st_size if out_csv.exists() else 0
            print(f"   -> wrote {sz} bytes in {dt:.1f}s")

        n = inject_msa(td, out_csv.resolve())
        print(f"   -> injected msa: into {n} yamls in {td.name}/")

    print()
    print("Done. Re-run run_boltz_batch.sh; boltz should skip MSA generation entirely.")


if __name__ == "__main__":
    main()
