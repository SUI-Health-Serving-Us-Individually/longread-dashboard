#!/usr/bin/env python3
"""add_hg19.py — add a `pos_hg19` (GRCh37/hg19) column to a variants table.

The dashboard's "Location (hg19)" column reads an optional `pos_hg19` column.
hg38 -> hg19 is a liftOver (region-specific remapping), not arithmetic, so this
script lifts each row's (chrom, pos) with the UCSC chain and writes the hg19
position back as a new column. Works on a Parquet or a TSV.

Usage
-----
    pip install pyliftover pyarrow        # pyarrow only needed for .parquet

    # Parquet in/out (downloads the hg38->hg19 chain automatically the first time):
    python add_hg19.py --in variants.parquet --out variants.parquet

    # TSV in/out, with an explicit local chain (for offline use):
    #   chain: https://hgdownload.soe.ucsc.edu/goldenPath/hg38/liftOver/hg38ToHg19.over.chain.gz
    python add_hg19.py --in variants.tsv --out variants.tsv --chain hg38ToHg19.over.chain.gz

Notes
-----
* VCF/Parquet positions are 1-based; UCSC liftOver is 0-based — handled here.
* Positions that don't lift (deleted/changed regions) are left empty, and the
  dashboard simply shows "—" for them.
* Only chrom+pos are lifted (point lift of the start position) — enough to
  cross-reference hg19-based resources like ALSoD. It does not re-validate
  ref/alt against the hg19 sequence; use a full VCF liftover (CrossMap /
  Picard LiftoverVcf) if you need allele-level correctness.
"""
import argparse
import sys


def build_lifter(chain_path):
    try:
        from pyliftover import LiftOver
    except ImportError:
        sys.exit("Missing dependency: pip install pyliftover")
    # With an explicit chain file, use it; otherwise let pyliftover fetch
    # the hg38->hg19 chain from UCSC (cached after first download).
    return LiftOver(chain_path) if chain_path else LiftOver("hg38", "hg19")


def make_lift_fn(lo):
    def lift(chrom, pos):
        if chrom is None or pos is None:
            return None
        try:
            pos = int(pos)
        except (TypeError, ValueError):
            return None
        c = chrom if str(chrom).startswith("chr") else "chr" + str(chrom)
        try:
            res = lo.convert_coordinate(c, pos - 1)  # 0-based query
        except Exception:
            return None
        if not res:
            return None
        return int(res[0][1]) + 1  # back to 1-based
    return lift


def run_parquet(inp, out, lift, chrom_col, pos_col):
    import pyarrow as pa
    import pyarrow.parquet as pq
    t = pq.read_table(inp)
    if chrom_col not in t.column_names or pos_col not in t.column_names:
        sys.exit(f"Parquet is missing '{chrom_col}'/'{pos_col}' columns: {t.column_names}")
    chrom = t.column(chrom_col).to_pylist()
    pos = t.column(pos_col).to_pylist()
    hg19 = [lift(c, p) for c, p in zip(chrom, pos)]
    if "pos_hg19" in t.column_names:
        t = t.drop(["pos_hg19"])
    t = t.append_column("pos_hg19", pa.array(hg19, type=pa.int64()))
    pq.write_table(t, out)
    return sum(1 for x in hg19 if x is not None), len(hg19)


def run_tsv(inp, out, lift, chrom_col, pos_col):
    import csv
    with open(inp, newline="") as f:
        reader = csv.DictReader(f, delimiter="\t")
        if chrom_col not in reader.fieldnames or pos_col not in reader.fieldnames:
            sys.exit(f"TSV is missing '{chrom_col}'/'{pos_col}' columns: {reader.fieldnames}")
        fields = [c for c in reader.fieldnames if c != "pos_hg19"] + ["pos_hg19"]
        rows = list(reader)
    lifted = 0
    for r in rows:
        h = lift(r.get(chrom_col), r.get(pos_col))
        r["pos_hg19"] = "" if h is None else h
        if h is not None:
            lifted += 1
    with open(out, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=fields, delimiter="\t", extrasaction="ignore")
        w.writeheader()
        w.writerows(rows)
    return lifted, len(rows)


def main():
    ap = argparse.ArgumentParser(description="Add a pos_hg19 column via hg38->hg19 liftOver.")
    ap.add_argument("--in", dest="inp", required=True, help="input .parquet or .tsv")
    ap.add_argument("--out", dest="out", required=True, help="output .parquet or .tsv")
    ap.add_argument("--chain", help="UCSC hg38ToHg19 chain (.over.chain[.gz]); omit to auto-download")
    ap.add_argument("--chrom-col", default="chrom")
    ap.add_argument("--pos-col", default="pos")
    a = ap.parse_args()

    lift = make_lift_fn(build_lifter(a.chain))
    runner = run_parquet if a.inp.endswith(".parquet") else run_tsv
    lifted, total = runner(a.inp, a.out, lift, a.chrom_col, a.pos_col)
    pct = (100 * lifted / total) if total else 0
    print(f"Lifted {lifted:,}/{total:,} rows ({pct:.1f}%) to hg19; wrote {a.out}")
    if lifted < total:
        print(f"  {total - lifted:,} rows did not lift and have an empty pos_hg19 (shown as '—').")


if __name__ == "__main__":
    main()
