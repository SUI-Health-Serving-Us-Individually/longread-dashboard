# Long-Read Sequencing Variant Dashboard

**By [SUI Health](mailto:contact@suihealth.com)**

A single-file, self-contained HTML dashboard for interactively browsing variants
from a long-read (PacBio HiFi) whole-genome sequencing run. It opens in any
modern browser, needs no build step and no backend, and queries millions of
variants client-side using [DuckDB-WASM](https://duckdb.org/docs/api/wasm/overview).

> ### 🧪 This repository ships **synthetic demo data**
> Every variant, structural variant, and repeat genotype in this repo is
> **randomly generated** — it is **not** from any real person. The demo exists
> so the dashboard is runnable out of the box. To analyze a real sample, replace
> the data files (see [Build your own Parquet](#build-your-own-parquet-from-pacbio-data)).
>
> ### 🔒 Do **not** commit real patient data to this (or any) public repo
> A whole-genome variant set is **identifying protected health information** —
> removing the name does **not** make it safe to share. See
> [Real data & privacy](#real-data--privacy) before using this with a real sample.

---

## Tabs

| Tab | What it shows | Data source |
|-----|---------------|-------------|
| **ClinVar Pathogenic** | Variants with pathogenic / likely-pathogenic ClinVar assertions, genome-wide across all genes and conditions. | Embedded in the HTML |
| **All Variants (Full Genome)** | Every record from the VEP-annotated VCF — fully filterable and sortable (gene, position, impact, CADD/REVEL/SpliceAI/SIFT/PolyPhen, gnomAD AF, zygosity, ClinVar). | `variants.parquet` |
| **All SVs (Full Genome)** | Every structural-variant call (DEL/DUP/INV/INS/BND/CNV), with type/size/depth/quality filters. | `svs.parquet` |
| **Repeat Expansions (TRGT)** | Tandem-repeat genotypes from PacBio TRGT, with per-locus waterfall plots and clinical threshold flags. | Embedded + SVGs in `longread_dashboard_assets/` |

Each tab has a collapsible **Column guide** explaining every column, and the
All Variants tab explains why homozygous-reference (`0/0`) and no-call (`./.`)
records appear (with a live breakdown computed from the loaded data).

---

## Quick start

```bash
git clone <your-repo-url>
cd longread_dashboard_public
./serve_dashboard.sh
```

This starts a tiny local web server and opens the dashboard in your browser with
the synthetic demo data loaded. Leave the terminal open while you use it; press
**Ctrl-C** to stop.

Options:

```bash
./serve_dashboard.sh 8765        # use a specific port
./serve_dashboard.sh --no-open   # don't auto-open the browser
./serve_dashboard.sh --dir /path # serve a different directory
```

### Load your own data — in the browser, nothing uploaded

The top of the page has a **"Use your own data"** bar with two file pickers
(**Variants** and **SVs**). Choose a `.parquet` file and it's read **locally in
your browser** (via DuckDB-WASM's in-memory filesystem) — **nothing is ever sent
to a server.** This is the recommended way to look at a real sample.

Loading your own data:

- replaces the synthetic demo with your file in the All Variants / All SVs tab,
- re-derives the **ClinVar** tab from your variants (pathogenic / likely-pathogenic),
- clears the synthetic TRGT repeat demo (repeats can't come from a Parquet), and
- switches the banner to "your own data is loaded locally."

Reload the page to return to the demo. Your files are expected to match the
[schemas below](#expected-schemas). Because this path downloads/registers the
whole file in memory, it's best for per-sample Parquets up to a few hundred MB;
for very large files served over HTTP, the dashboard range-scans instead (see
[How it works](#how-it-works)).

### Why a server? Why not just double-click the HTML?

The **All Variants** and **All SVs** tabs read the Parquet sidecars via HTTP
**range requests**, so DuckDB only fetches the row groups each query touches
instead of downloading the whole file. Browsers block range requests on
`file://` URLs, so opening the HTML directly makes those two tabs fail to load.
`serve_dashboard.sh` wraps Python's standard `http.server` to add range support.

(The ClinVar and TRGT tabs work from a plain `file://` open — their data is
embedded in the HTML — but the genome-scale tabs need the server.)

---

## Requirements

- **Python 3** (standard library only). Used solely to run the local server.
- **A modern browser** (Chrome, Firefox, Edge, Safari).
- **Internet access on first load** of the All Variants / All SVs tabs — they
  load DuckDB-WASM, and the page loads Chart.js, from a CDN
  (`cdn.jsdelivr.net`, `cdnjs.cloudflare.com`). The ClinVar and TRGT tabs work
  fully offline.

No installation, virtualenv, or `npm` step is required to *run* the dashboard.

---

## Repository layout

```
longread_dashboard_public/
├── longread_dashboard.html        # the dashboard (synthetic ClinVar + TRGT data embedded)
├── variants.parquet               # synthetic SNV/indel demo (~160 KB, 3,000 rows)
├── svs.parquet                    # synthetic structural-variant demo (~20 KB, 300 rows)
├── longread_dashboard_assets/
│   └── trgt/                       # synthetic placeholder waterfall plots (SVG)
├── serve_dashboard.sh             # local HTTP server with range-request support
├── add_hg19.py                    # add a pos_hg19 column to a Parquet/TSV via liftOver
├── LICENSE                        # MIT © 2026 SUI Health
└── README.md
```

The synthetic data is small and commits to GitHub with no issues. Real data is a
different story — see below.

---

## Real data & privacy

This dashboard is a **tool**; the demo data is disposable. When you point it at a
real sample, the data — not the code — becomes the sensitive part.

- **A whole-genome variant set is identifying PHI.** Dropping the patient name
  does *not* de-identify a genome; genotype profiles are inherently
  re-identifiable, even subsetted to a few loci.
- **Do not put real patient data in a Git repository** — public *or* private,
  and not via Git LFS. Git history is sticky, and code hosts are not an
  appropriate store for PHI (no BAA, no clinical-grade access controls).
- **Keep real instances off GitHub entirely.** Run the dashboard locally against
  data on access-controlled storage (encrypted institutional storage, or a
  HIPAA-eligible cloud bucket under a BAA with proper IAM — never a public
  object). To share with a clinician/collaborator, use private, access-controlled
  delivery (e.g. a password-protected link) or screen-share a local session.
- **Confirm governance first.** Consent to share, IRB/data-use agreements, and
  HIPAA obligations are determined by your institution's privacy/compliance
  owner, not by this tool. This README is general data-handling guidance, not
  legal advice.

---

## How it works

- **One HTML file.** All CSS, JavaScript, the ClinVar table, and the TRGT
  genotypes/thresholds are embedded directly in `longread_dashboard.html`.
- **Parquet sidecars for scale.** The two genome-wide tabs don't embed millions
  of rows; they query `variants.parquet` / `svs.parquet` with DuckDB-WASM
  running in the browser. Filtering and sorting stay responsive at
  whole-genome scale because DuckDB range-fetches only the bytes it needs.
- **No backend.** The only server is a static file server that supports HTTP
  range requests.

---

## Build your own Parquet from PacBio data

The genome-wide tabs are driven entirely by two Parquet files. Below is an
end-to-end recipe to produce them from raw **PacBio HiFi** reads. The tool
versions are examples; newer releases generally work.

### 1. Call variants from HiFi reads

```bash
# Align HiFi reads to the reference (GRCh38)
pbmm2 align --preset CCS --sort GRCh38.fa hifi_reads.bam aligned.bam

# Small variants (SNVs + indels)  →  DeepVariant
run_deepvariant --model_type=PACBIO \
  --ref=GRCh38.fa --reads=aligned.bam --output_vcf=deepvariant.vcf.gz

# Structural variants  →  pbsv
pbsv discover aligned.bam sv.svsig.gz
pbsv call GRCh38.fa sv.svsig.gz pbsv.vcf.gz

# Tandem-repeat expansions  →  TRGT (also produces the waterfall plots)
trgt genotype --genome GRCh38.fa --reads aligned.bam \
  --repeats repeat_catalog.bed --output-prefix trgt
```

### 2. Annotate with VEP

Annotate the DeepVariant (and pbsv) VCFs with Ensembl VEP, adding the plugins
the dashboard's score columns expect:

```bash
vep --offline --cache --assembly GRCh38 --fasta GRCh38.fa \
    --vcf --everything --force_overwrite \
    --plugin CADD,cadd_scores.tsv.gz \
    --plugin REVEL,revel_scores.tsv.gz \
    --plugin SpliceAI,snv=spliceai_snv.vcf.gz,indel=spliceai_indel.vcf.gz \
    --custom clinvar.vcf.gz,ClinVar,vcf,exact,0,CLNSIG,CLNDN \
    -i deepvariant.vcf.gz -o annotated.vcf.gz --compress_output bgzip
```

> The exact VEP **CSQ sub-field names** depend on your VEP version and plugins.
> List what's actually in your file with
> `bcftools +split-vep -l annotated.vcf.gz` and adjust the field names in the
> next step to match.

### 3. Flatten the VCF to a tab-delimited table

[`bcftools +split-vep`](https://samtools.github.io/bcftools/howtos/plugin.split-vep.html)
expands the VEP CSQ string into one column per field. Write a header line whose
names **exactly match** the schema below, then the rows:

```bash
# variants.parquet source
{ printf 'chrom\tpos\tref\talt\tqual\tfilter\tgene\tconsequence\timpact\tbiotype\thgvsp\thgvsc\tmane\texon\tgt\tsift\tpolyphen\tcadd\trevel\tspliceai\texisting\tgnomadg\tgnomade\tmax_af\tclinsig\tclndn\n'
  bcftools +split-vep annotated.vcf.gz -d -A tab \
    -f '%CHROM\t%POS\t%REF\t%ALT\t%QUAL\t%FILTER\t%SYMBOL\t%Consequence\t%IMPACT\t%BIOTYPE\t%HGVSp\t%HGVSc\t%MANE_SELECT\t%EXON\t[%GT]\t%SIFT\t%PolyPhen\t%CADD_PHRED\t%REVEL\t%SpliceAI_pred_DS_AG\t%Existing_variation\t%gnomADg_AF\t%gnomADe_AF\t%MAX_AF\t%CLNSIG\t%CLNDN\n'
} > variants.tsv
```

For structural variants, pull the SV-specific INFO/FORMAT fields:

```bash
# svs.parquet source
{ printf 'chrom\tpos\tend_pos\tvid\tref\talt\tqual\tfilter\tsvtype\tsvlen\tprecise\tgt\tad\tdp\tgene\tconsequence\timpact\tbiotype\thgvsc\thgvsp\n'
  bcftools +split-vep pbsv.annotated.vcf.gz -d -A tab \
    -f '%CHROM\t%POS\t%END\t%ID\t%REF\t%ALT\t%QUAL\t%FILTER\t%SVTYPE\t%SVLEN\t%PRECISE\t[%GT]\t[%AD]\t[%DP]\t%SYMBOL\t%Consequence\t%IMPACT\t%BIOTYPE\t%HGVSc\t%HGVSp\n'
} > svs.tsv
```

### 4. Convert TSV → Parquet

Using the [DuckDB CLI](https://duckdb.org/docs/installation/) (one line, fast):

```bash
duckdb -c "COPY (SELECT * FROM read_csv('variants.tsv', delim='\t', header=true, sample_size=-1)) TO 'variants.parquet' (FORMAT PARQUET);"
duckdb -c "COPY (SELECT * FROM read_csv('svs.tsv',      delim='\t', header=true, sample_size=-1)) TO 'svs.parquet' (FORMAT PARQUET);"
```

Or with Python + pyarrow:

```python
import pyarrow.csv as csv, pyarrow.parquet as pq
for name in ("variants", "svs"):
    t = csv.read_csv(f"{name}.tsv", parse_options=csv.ParseOptions(delimiter="\t"))
    pq.write_table(t, f"{name}.parquet")
```

Drop the two `.parquet` files into the dashboard folder, replacing the demo
files. **Keep them local — do not commit a real sample (see
[Real data & privacy](#real-data--privacy)).**

### Expected schemas

The dashboard reads these column names. Extra columns are ignored; missing
optional columns simply render blank.

**`variants.parquet`** — one row per VEP-annotated VCF record:

| column | meaning |
|--------|---------|
| `chrom`, `pos`, `ref`, `alt` | locus and alleles (GRCh38) |
| `qual`, `filter` | VCF QUAL and FILTER |
| `gene`, `consequence`, `impact`, `biotype` | VEP annotation |
| `hgvsp`, `hgvsc`, `mane`, `exon` | HGVS / transcript context |
| `gt` | genotype (`0/1`, `1/1`, `0/0`, `./.`, …) |
| `cadd`, `revel`, `spliceai`, `sift`, `polyphen` | pathogenicity scores |
| `gnomadg`, `gnomade`, `max_af` | population allele frequencies |
| `clinsig`, `clndn` | ClinVar significance and disease |
| `existing` | known variant IDs (dbSNP rsIDs, etc.) |
| `pos_hg19` | *(optional)* GRCh37/hg19 position — populates the "Location (hg19)" column. See [Comparing to ALSoD](#comparing-to-alsod--lifting-to-hg19). |

**`svs.parquet`** — one row per structural-variant call:

| column | meaning |
|--------|---------|
| `chrom`, `pos`, `end_pos`, `vid` | locus, span, caller ID |
| `svtype`, `svlen`, `precise` | type, length, breakpoint precision |
| `gt`, `ad`, `dp`, `qual`, `filter` | genotype, allelic depth, depth, quality, FILTER |
| `gene`, `consequence`, `impact`, `biotype`, `hgvsc`, `hgvsp` | VEP annotation (optional) |

### ClinVar table & TRGT plots (embedded)

The **ClinVar** table and **TRGT** loci/plots live inside the HTML (the
`const DATA = { … }` object) and in `longread_dashboard_assets/trgt/`. To swap
them for a new sample:

- Replace the `clinvar_variants` and `trgt_loci` arrays in `DATA` (e.g. derive
  ClinVar rows from your annotated VCF, and TRGT rows from the TRGT VCF), and
  update `DATA.sample` / the counts in the header.
- Regenerate the per-locus waterfall SVGs and name them
  `<DATA.sample>.<TRID>.waterfall.svg` (the demo uses the prefix `DEMO`, so files
  are `DEMO.<TRID>.waterfall.svg`). Keep `DATA.sample` and the filename prefix in
  sync.

---

## Comparing to ALSoD / lifting to hg19

[ALSoD](https://alsod.ac.uk/) (the ALS Online Database) is organised **by gene**
and lists reported mutations largely by **protein change** and **rsID**. So the
most reliable way to check a variant against ALSoD is to match on **gene +
protein change (HGVS p.)** and **dbSNP rsID** — all of which the dashboard
already shows and lets you filter/search. Workflow: open **All Variants**, set
the **Gene** filter to an ALS gene, and compare the Protein / dbSNP columns to
that gene's ALSoD page.

For **coordinate-level** checks, note that ALSoD and many older ALS resources use
**GRCh37 / hg19**, while this dashboard (and PacBio pipelines) use **GRCh38**.
You cannot convert hg38 → hg19 by arithmetic — it requires a **liftOver** (a
region-specific remapping). The dashboard therefore shows an hg19 position only
if your Parquet carries a `pos_hg19` column.

**Easiest way — the bundled `add_hg19.py` script.** It lifts each row and adds
the `pos_hg19` column to a Parquet (or TSV) in place:

```bash
pip install pyliftover pyarrow
python add_hg19.py --in variants.parquet --out variants.parquet
# (downloads the UCSC hg38→hg19 chain automatically the first time;
#  pass --chain hg38ToHg19.over.chain.gz to run offline)
```

Then reload the dashboard and load that Parquet — the **Location (hg19)** column
fills in, and each hg19 cell links straight to the UCSC browser (hg19).

For allele-level correctness (re-validating ref/alt against the hg19 sequence),
use a full VCF liftover instead — e.g.
[CrossMap](https://crossmap.readthedocs.io/) or Picard `LiftoverVcf` — and carry
the lifted position into the Parquet as `pos_hg19`. Positions that don't lift are
left blank and show as "—".

### Quick cross-reference links

Each row links out to make checking against external databases one click:

- **Location (hg38)** → the variant (or region) in **gnomAD** (GRCh38),
- **Location (hg19)** → the locus in the **UCSC browser** (hg19),
- **dbSNP / IDs** → each rsID on **dbSNP**.

> The hg19 values in the bundled demo are **placeholder offsets**, not a real
> liftOver — the demo data is synthetic.

---

## Genotypes: why `0/0` and `./.` appear

The All Variants tab shows the caller's **complete** output, not just confident
variant calls. A caller such as DeepVariant emits a record at every site it
evaluated and tags each with a FILTER:

- **`PASS` → `0/1`, `1/1`, …** — a real variant in this sample.
- **`RefCall` → `0/0`** — the site looked variant-like but the caller decided
  this sample is homozygous reference (no alt allele).
- **`NoCall` → `./.`** — too little / too ambiguous evidence to genotype.

So `0/0` and `./.` rows are *not* variants the individual carries. Use the
**"Hide 0/0 and ./."** checkbox (or the Zygosity → "HET or HOM" filter) to drop
them. The dashboard shows the exact breakdown for the loaded data. (The synthetic
demo deliberately includes a realistic mix of all three so this is visible.)

---

## Disclaimer

This is a **research / data-exploration tool, not a diagnostic device.** Nothing
it displays is validated for clinical use. Variant pathogenicity, repeat-length
thresholds, and all annotations should be confirmed independently
(e.g. orthogonal assays, clinical-grade pipelines, expert review) before any
clinical interpretation or action.

---

## License

Released under the [MIT License](LICENSE) — Copyright (c) 2026 SUI Health.

The MIT license covers the dashboard software only. Any third-party annotation
data you use with it (ClinVar, gnomAD, CADD, REVEL, SpliceAI, etc.) carries its
own terms of use.

---

<sub>Built by SUI Health · contact@suihealth.com</sub>
