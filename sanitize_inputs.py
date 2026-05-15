"""Copy Boltz_ligands/<TARGET>/wt/input/*.yaml into Boltz_output/_fixed_inputs/<TARGET>/,
fixing two recurring issues:
  1. protein `sequence:` value wrapped across multiple lines (CASR)
  2. missing space after `sequence:` (CNR1)
Stray non-yaml files (DRD4/boltz.job, ROCK1/go) are skipped.
After writing, every output yaml is re-parsed to confirm it loads.
"""
import os, re, sys, shutil, glob
import yaml

LIG_ROOT = "/work/jwang/boltz2/Boltz_ligands"
OUT_ROOT = "/work/jwang/boltz2/Boltz_output/_fixed_inputs"

SEQ_LINE_RE = re.compile(r"^(\s*sequence:)\s*(.*)$")


def fix_yaml_text(text: str) -> str:
    """Rewrite a single yaml file's text:
       - ensure exactly one space after `sequence:`
       - if the sequence value continues on the next line(s) without proper YAML
         continuation, glue continuation lines onto the sequence line.
    """
    lines = text.splitlines()
    out = []
    i = 0
    while i < len(lines):
        line = lines[i]
        m = SEQ_LINE_RE.match(line)
        if not m:
            out.append(line)
            i += 1
            continue
        prefix, value = m.group(1), m.group(2).strip()
        # Find indent of `sequence:` key
        indent = len(line) - len(line.lstrip())
        # Greedily consume continuation lines: any subsequent line whose
        # leading non-whitespace char is a residue letter (A-Z) and whose
        # indent is <= the sequence-key indent (i.e. not a deeper map entry).
        j = i + 1
        while j < len(lines):
            nxt = lines[j]
            stripped = nxt.strip()
            if not stripped:
                break
            # stop if this looks like a new yaml key/list entry
            if stripped.startswith("-") or ":" in stripped.split()[0]:
                break
            # stop if it's clearly indented deeper as a child map (has key:)
            if re.match(r"^\s*[A-Za-z_][\w-]*\s*:", nxt):
                break
            # only fold if line consists of residue characters
            if not re.match(r"^[A-Za-z\*\-]+$", stripped):
                break
            value += stripped
            j += 1
        out.append(f"{prefix} {value}")
        i = j
    return "\n".join(out) + ("\n" if text.endswith("\n") else "")


def main():
    os.makedirs(OUT_ROOT, exist_ok=True)
    grand_total = 0
    grand_fixed = 0
    grand_failed = 0
    grand_skipped_stray = 0

    for target in sorted(os.listdir(LIG_ROOT)):
        in_dir = os.path.join(LIG_ROOT, target, "wt", "input")
        if not os.path.isdir(in_dir):
            continue
        out_dir = os.path.join(OUT_ROOT, target)
        os.makedirs(out_dir, exist_ok=True)

        total = 0
        fixed = 0
        failed = []
        stray = []

        for name in sorted(os.listdir(in_dir)):
            src = os.path.join(in_dir, name)
            if not name.endswith(".yaml"):
                stray.append(name)
                continue
            total += 1
            with open(src) as fh:
                raw = fh.read()

            try:
                yaml.safe_load(raw)
                # already valid -> copy as-is
                shutil.copyfile(src, os.path.join(out_dir, name))
                continue
            except yaml.YAMLError:
                pass

            new_text = fix_yaml_text(raw)
            try:
                yaml.safe_load(new_text)
            except yaml.YAMLError as e:
                failed.append((name, str(e).splitlines()[0]))
                continue

            with open(os.path.join(out_dir, name), "w") as fh:
                fh.write(new_text)
            fixed += 1

        grand_total += total
        grand_fixed += fixed
        grand_failed += len(failed)
        grand_skipped_stray += len(stray)

        print(f"{target:<10} total={total:<4} fixed={fixed:<4} still_failed={len(failed):<3} stray_skipped={len(stray)}")
        for name, msg in failed[:3]:
            print(f"    FAILED {name}: {msg}")
        for s in stray:
            print(f"    SKIPPED stray: {s}")

    print()
    print(f"TOTALS: yamls={grand_total} fixed={grand_fixed} still_failed={grand_failed} stray_skipped={grand_skipped_stray}")
    print(f"Sanitized tree: {OUT_ROOT}")
    return 0 if grand_failed == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
