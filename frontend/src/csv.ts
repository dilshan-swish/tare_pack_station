// Minimal RFC 4180 CSV parser — the backend's CSV exports quote any field
// containing a comma, quote, or newline (an override reason with a comma in
// it, say), so a naive `line.split(",")` would misalign columns on exactly
// the rows worth reading carefully. Shared by anything that reads one of
// those exports back (the Weigh History preview used to inline this; the
// Calibrator needs the exact same parsing for its uploaded file).
export function parseCsv(text: string): string[][] {
  const rows: string[][] = [];
  let row: string[] = [];
  let field = "";
  let inQuotes = false;
  for (let i = 0; i < text.length; i++) {
    const c = text[i];
    if (inQuotes) {
      if (c === '"') {
        if (text[i + 1] === '"') {
          field += '"';
          i++;
        } else {
          inQuotes = false;
        }
      } else {
        field += c;
      }
    } else if (c === '"') {
      inQuotes = true;
    } else if (c === ",") {
      row.push(field);
      field = "";
    } else if (c === "\n") {
      row.push(field);
      rows.push(row);
      row = [];
      field = "";
    } else if (c === "\r") {
      // skip — the following \n closes the row
    } else {
      field += c;
    }
  }
  if (field.length > 0 || row.length > 0) {
    row.push(field);
    rows.push(row);
  }
  // A trailing blank line after the final \n parses as one empty field —
  // drop it so it doesn't show as a phantom last row.
  return rows.filter((r) => !(r.length === 1 && r[0] === ""));
}

/// Parses a CSV's rows into objects keyed by its own header row — the shape
/// every caller actually wants, rather than re-zipping header/row pairs by
/// hand at every call site.
export function parseCsvObjects(text: string): { header: string[]; rows: Record<string, string>[] } {
  const parsed = parseCsv(text);
  const [header, ...dataRows] = parsed;
  if (!header) return { header: [], rows: [] };
  const rows = dataRows.map((r) => {
    const obj: Record<string, string> = {};
    header.forEach((h, i) => {
      obj[h] = r[i] ?? "";
    });
    return obj;
  });
  return { header, rows };
}
