#!/usr/bin/env python3
"""Render FileFS bench results as a colored HTML matrix + SVG heatmap in README."""

from __future__ import annotations

import html
import json
import math
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
BENCH = Path(__file__).resolve().parent
RESULTS = BENCH / "results" / "latest.json"
README = ROOT / "README.md"
SVG_PATH = BENCH / "matrix.svg"
WORKLOAD = json.loads((BENCH / "workload.json").read_text(encoding="utf-8"))

BEGIN = "<!-- BENCH_MATRIX_BEGIN -->"
END = "<!-- BENCH_MATRIX_END -->"

# Relative heatmap within each row (green=fast .. red=slow)
PALETTE = [
    "#1b7f4e",  # best
    "#57a773",
    "#c7e89a",
    "#f9e79f",
    "#f5b041",
    "#e67e22",
    "#c0392b",  # worst
]
NA_COLOR = "#7f8c8d"
HEADER_BG = "#2c3e50"
HEADER_FG = "#ecf0f1"


def load_results() -> dict:
    if not RESULTS.exists():
        return {
            "workload": WORKLOAD,
            "languages": {},
            "errors": {},
            "generated_at_unix": None,
        }
    return json.loads(RESULTS.read_text(encoding="utf-8"))


def format_ns(ns: float | None) -> str:
    if ns is None or not math.isfinite(ns):
        return "—"
    if ns >= 1_000_000_000:
        return f"{ns / 1_000_000_000:.2f}s"
    if ns >= 1_000_000:
        return f"{ns / 1_000_000:.2f}ms"
    if ns >= 1_000:
        return f"{ns / 1_000:.1f}µs"
    return f"{ns:.0f}ns"


def color_for_rank(rank: int, n: int) -> str:
    if n <= 1:
        return PALETTE[0]
    # map rank 0..n-1 onto palette indices
    idx = round(rank * (len(PALETTE) - 1) / (n - 1))
    return PALETTE[idx]


def build_matrix(
    doc: dict,
) -> tuple[list[str], list[str], dict[str, dict[str, float | None]], dict[str, str]]:
    op_ids = [op["id"] for op in WORKLOAD["ops"]]
    op_labels = {op["id"]: op["label"] for op in WORKLOAD["ops"]}
    lang_order = [lang for lang in WORKLOAD["languages"] if lang in doc.get("languages", {})]
    for lang in sorted(doc.get("languages", {})):
        if lang not in lang_order:
            lang_order.append(lang)

    values: dict[str, dict[str, float | None]] = {op: {} for op in op_ids}
    for lang in lang_order:
        ops = doc["languages"][lang].get("ops", {})
        for op in op_ids:
            entry = ops.get(op)
            if not entry:
                values[op][lang] = None
            else:
                values[op][lang] = float(entry["ns_per_op"])
    return lang_order, op_ids, values, op_labels


def row_colors(row: dict[str, float | None]) -> dict[str, str]:
    present = [(lang, ns) for lang, ns in row.items() if ns is not None]
    present.sort(key=lambda item: item[1])
    colors: dict[str, str] = {}
    for rank, (lang, _) in enumerate(present):
        colors[lang] = color_for_rank(rank, len(present))
    for lang, ns in row.items():
        if ns is None:
            colors[lang] = NA_COLOR
    return colors


def render_html(doc: dict) -> str:
    lang_order, op_ids, values, op_labels = build_matrix(doc)
    if not lang_order:
        return (
            "_No benchmark results yet. Run `python3 bench/run_all.py` "
            "to generate the matrix._\n"
        )

    lines = []
    lines.append("<table>")
    lines.append("<thead><tr>")
    lines.append(
        f'<th bgcolor="{HEADER_BG}"><font color="{HEADER_FG}">API \\ Lang</font></th>'
    )
    for lang in lang_order:
        lines.append(
            f'<th bgcolor="{HEADER_BG}"><font color="{HEADER_FG}">{html.escape(lang)}</font></th>'
        )
    lines.append("</tr></thead><tbody>")

    for op in op_ids:
        colors = row_colors(values[op])
        lines.append("<tr>")
        lines.append(
            f'<th bgcolor="#34495e"><font color="{HEADER_FG}">{html.escape(op_labels[op])}</font></th>'
        )
        for lang in lang_order:
            ns = values[op][lang]
            cell = format_ns(ns)
            title = f"{lang} / {op}: {ns:.0f} ns/op" if ns is not None else f"{lang} / {op}: n/a"
            lines.append(
                f'<td bgcolor="{colors[lang]}" title="{html.escape(title)}" align="right">'
                f"<code>{html.escape(cell)}</code></td>"
            )
        lines.append("</tr>")
        lines.append("</tbody></table>")
    return "\n".join(lines) + "\n"


def render_errors(doc: dict) -> str:
    errors = doc.get("errors") or {}
    if not errors:
        return ""
    lines = [
        "<details><summary>Skipped / failed runners</summary>",
        "",
    ]
    for lang, message in sorted(errors.items()):
        safe = html.escape(message.replace("\n", " ")[:300])
        lines.append(f"- **{html.escape(lang)}**: `{safe}`")
    lines.extend(["", "</details>", ""])
    return "\n".join(lines)


def render_svg(doc: dict) -> str:
    lang_order, op_ids, values, op_labels = build_matrix(doc)
    if not lang_order:
        return '<svg xmlns="http://www.w3.org/2000/svg" width="640" height="80"><text x="12" y="40" fill="#7f8c8d">No benchmark results yet</text></svg>\n'

    label_w = 150
    col_w = 78
    row_h = 28
    header_h = 36
    width = label_w + col_w * len(lang_order) + 16
    height = header_h + row_h * len(op_ids) + 48

    parts = [
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}" font-family="ui-monospace, SFMono-Regular, Menlo, Consolas, monospace" font-size="11">',
        f'<rect width="100%" height="100%" fill="#111827"/>',
        f'<text x="12" y="18" fill="#e5e7eb" font-size="13">FileFS full-API benchmark matrix (lower is better)</text>',
    ]

    y0 = 32
    parts.append(f'<rect x="0" y="{y0}" width="{width}" height="{header_h}" fill="{HEADER_BG}"/>')
    parts.append(f'<text x="8" y="{y0 + 22}" fill="{HEADER_FG}">API</text>')
    for i, lang in enumerate(lang_order):
        x = label_w + i * col_w + 8
        parts.append(f'<text x="{x}" y="{y0 + 22}" fill="{HEADER_FG}">{html.escape(lang)}</text>')

    for r, op in enumerate(op_ids):
        y = y0 + header_h + r * row_h
        colors = row_colors(values[op])
        parts.append(f'<rect x="0" y="{y}" width="{label_w}" height="{row_h}" fill="#1f2937"/>')
        parts.append(
            f'<text x="8" y="{y + 18}" fill="#e5e7eb">{html.escape(op_labels[op])}</text>'
        )
        for i, lang in enumerate(lang_order):
            x = label_w + i * col_w
            ns = values[op][lang]
            parts.append(
                f'<rect x="{x}" y="{y}" width="{col_w}" height="{row_h}" fill="{colors[lang]}" stroke="#111827"/>'
            )
            parts.append(
                f'<text x="{x + col_w / 2}" y="{y + 18}" fill="#111827" text-anchor="middle">{html.escape(format_ns(ns))}</text>'
            )

    # legend
    ly = height - 22
    parts.append(f'<text x="8" y="{ly}" fill="#9ca3af">row-relative:</text>')
    labels = ["fast", "", "", "mid", "", "", "slow"]
    for i, color in enumerate(PALETTE):
        x = 100 + i * 46
        parts.append(f'<rect x="{x}" y="{ly - 12}" width="40" height="14" fill="{color}" rx="2"/>')
        if labels[i]:
            parts.append(f'<text x="{x + 20}" y="{ly - 16}" fill="#9ca3af" text-anchor="middle" font-size="9">{labels[i]}</text>')

    parts.append("</svg>\n")
    return "\n".join(parts)


def patch_readme(section: str) -> None:
    text = README.read_text(encoding="utf-8")
    block = f"{BEGIN}\n{section}{END}"
    if BEGIN in text and END in text:
        pre = text.split(BEGIN, 1)[0]
        post = text.split(END, 1)[1]
        text = pre + block + post
    else:
        # Append a Performance section
        text = text.rstrip() + "\n\n## Performance matrix\n\n" + block + "\n"
    README.write_text(text, encoding="utf-8")


def main() -> None:
    doc = load_results()
    html_table = render_html(doc)
    errors_md = render_errors(doc)
    svg = render_svg(doc)
    SVG_PATH.write_text(svg, encoding="utf-8")

    generated = doc.get("generated_at_unix")
    iters = doc.get("workload", {}).get("iterations", WORKLOAD["iterations"])
    payload = doc.get("workload", {}).get("payload_bytes", WORKLOAD["payload_bytes"])

    section_lines = [
        "",
        "Cross-language full-API microbenchmarks (`ns/op`, lower is better).",
        f"Workload: `{WORKLOAD['name']}` · iterations={iters} · payload={payload} bytes.",
        "Cell colors are **row-relative** (green = faster for that API among measured ports, red = slower).",
        "",
        "![FileFS benchmark matrix](bench/matrix.svg)",
        "",
        "<details><summary>Numeric matrix (HTML)</summary>",
        "",
        html_table.rstrip(),
        "",
        "</details>",
        "",
    ]
    if errors_md:
        section_lines.append(errors_md.rstrip())
        section_lines.append("")
    section_lines.extend(
        [
            "Regenerate:",
            "",
            "```bash",
            "python3 bench/run_all.py",
            "```",
            "",
            f"Raw results: [`bench/results/latest.json`](bench/results/latest.json)"
            + (f" · unix={generated}" if generated else "")
            + ".",
            "Harness details: [`bench/README.md`](bench/README.md).",
            "",
        ]
    )
    patch_readme("\n".join(section_lines))
    print(f"updated {README}")
    print(f"updated {SVG_PATH}")


if __name__ == "__main__":
    main()
