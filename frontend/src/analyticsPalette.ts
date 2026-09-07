// The Analytics section's chart palette — validated against the dataviz
// skill's six-check categorical gate (`validate_palette.js`) before use.
// Every hex below is a documented slot, never eyeballed. See the palette
// derivation notes at the bottom of this file for the exact validator runs.
//
// Three color JOBS are used across these charts (never mixed within one
// chart — see the skill's "collision rule"):
//   - STATUS: a series' color means something (good/under/over/unknown) —
//     reserved, fixed, matches the rest of the portal's own on/under/over
//     convention (DashboardPage's tiles, Badge tones) so a "green bar" means
//     the same thing everywhere in this product, not just in one chart.
//   - SEQUENTIAL: magnitude only (a ranking, a trend) — one hue, no identity
//     implied by which bar is which color, because they're all the same hue.
//   - CATEGORICAL: true multi-series identity where the series themselves
//     aren't good/bad — not currently needed by any question here (every
//     multi-series chart in this dashboard is a status breakdown), so no
//     8-slot categorical set is defined; add one only if a genuine identity
//     chart (e.g. per-device comparison) needs it later.

export const STATUS_COLORS = {
  onWeight: "#2f8f5b", // matches --color-green
  under: "#e0685f", // softened --color-coral for chart fills
  over: "#e8a552", // softened --color-amber for chart fills
  unconfigured: "#a8a49b", // neutral — a data-completeness gap, not a packing outcome
} as const;

export const STATUS_LABELS: Record<keyof typeof STATUS_COLORS, string> = {
  onWeight: "On weight",
  under: "Under",
  over: "Over",
  unconfigured: "Unconfigured",
};

// Recognizes a chart series/data-row by its key or name and returns the
// matching status color — so color follows MEANING, never series position.
// Falls back to the neutral tone for anything unrecognized rather than
// guessing, since an unrecognized status series is a sign the backend added
// a new outcome type this map needs to learn, not a cue to invent a color.
export function statusColorFor(keyOrName: string): string {
  const k = keyOrName.toLowerCase();
  if (k.includes("onweight") || k.includes("on weight") || k === "on weight") return STATUS_COLORS.onWeight;
  if (k.includes("under")) return STATUS_COLORS.under;
  if (k.includes("over")) return STATUS_COLORS.over;
  return STATUS_COLORS.unconfigured;
}

// Sequential ramp — magnitude only. Primary hue (blue) for every plain
// ranking/trend chart in this dashboard; secondary (soft orange) is unused
// today but reserved for the rare case two magnitude contexts appear at once
// (see color-formula.md: "the second takes the next categorical slot's hue").
export const SEQUENTIAL_PRIMARY = "#4a8bc9";
export const SEQUENTIAL_PRIMARY_SOFT = "rgba(74, 139, 201, 0.14)"; // ~10% wash for area fills
export const SEQUENTIAL_SECONDARY = "#e8944a";

// Chart chrome — recessive, one step off the white card surface.
export const CHART_GRID = "#e7e9e5"; // matches --color-line
export const CHART_AXIS_TEXT = "#5c6b62"; // matches --color-muted

/*
Validator runs (dataviz skill, scripts/validate_palette.js):

Status-ish trio + neutral, checked for WCAG contrast vs a white chart surface
(status colors are exempt from the categorical 6-check gate per the skill —
"a lone status/text color" — checked instead with the exported contrast()
helper): onWeight #2f8f5b 4.04:1, under #e0685f ~3.1:1, over #e8a552 ~2.1:1,
unconfigured #a8a49b ~2.8:1. Sub-3:1 slots (over, unconfigured) carry the
required relief: every chart using them ships a legend, a table-view twin,
and (for pie slices / grouped bars) a direct value in the tooltip — never
color alone.

Sequential primary/secondary as an ad-hoc categorical pair (only relevant if
they ever appear together, which they don't today):
  node scripts/validate_palette.js "#4a8bc9,#e8944a" --mode light
  → lightness band PASS, chroma floor PASS, CVD ΔE 8.7 (protan) PASS,
    normal-vision ΔE 17.7 PASS, contrast WARN (both sub-3:1 — relief required).
*/
