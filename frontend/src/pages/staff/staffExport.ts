// Client-side CSV / Excel export of whatever table the admin is looking at.
// SheetJS is loaded on demand so it doesn't weigh down the portal's first load.

type Cell = string | number | boolean | null | undefined;

function stamp() {
  const d = new Date();
  const p = (n: number) => String(n).padStart(2, "0");
  return `${d.getFullYear()}${p(d.getMonth() + 1)}${p(d.getDate())}-${p(d.getHours())}${p(d.getMinutes())}`;
}

function download(blob: Blob, filename: string) {
  const url = URL.createObjectURL(blob);
  const a = document.createElement("a");
  a.href = url;
  a.download = filename;
  document.body.appendChild(a);
  a.click();
  a.remove();
  window.setTimeout(() => URL.revokeObjectURL(url), 1000);
}

function csvCell(v: Cell): string {
  if (v === null || v === undefined) return "";
  const s = String(v);
  // Neutralise spreadsheet formula injection from free-text fields.
  const safe = /^[=+\-@]/.test(s) && typeof v === "string" ? `'${s}` : s;
  return /[",\n\r]/.test(safe) ? `"${safe.replace(/"/g, '""')}"` : safe;
}

export async function exportRows(kind: "csv" | "xlsx", name: string, headers: string[], rows: Cell[][]): Promise<void> {
  const filename = `${name}-${stamp()}.${kind}`;
  if (kind === "csv") {
    const text = [headers, ...rows].map((r) => r.map(csvCell).join(",")).join("\r\n");
    // BOM so Excel opens UTF-8 (™, Arabic) correctly.
    download(new Blob(["﻿" + text], { type: "text/csv;charset=utf-8" }), filename);
    return;
  }
  const XLSX = await import("xlsx");
  const ws = XLSX.utils.aoa_to_sheet([headers, ...rows]);
  ws["!cols"] = headers.map((h, i) => ({
    wch: Math.min(48, Math.max(h.length, ...rows.slice(0, 500).map((r) => String(r[i] ?? "").length)) + 2),
  }));
  ws["!autofilter"] = { ref: XLSX.utils.encode_range({ s: { r: 0, c: 0 }, e: { r: Math.max(rows.length, 1), c: headers.length - 1 } }) };
  const wb = XLSX.utils.book_new();
  XLSX.utils.book_append_sheet(wb, ws, name.slice(0, 31));
  const out = XLSX.write(wb, { bookType: "xlsx", type: "array" }) as ArrayBuffer;
  download(new Blob([out], { type: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet" }), filename);
}
