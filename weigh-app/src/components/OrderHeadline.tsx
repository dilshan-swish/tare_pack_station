import type { ApiOrder } from "../lib/types";
import { aggregatorTone, orderHeadline, orderSubline } from "../lib/format";

/**
 * The order's identity, led by what staff match against the bag's slip: the
 * aggregator (Keeta, Talabat…) and its own number, big; the POS order and
 * check number underneath.
 */
export function OrderHeadline({ order, size = "md" }: { order: ApiOrder; size?: "md" | "lg" }) {
  const { label, number } = orderHeadline(order);
  const sub = orderSubline(order);
  const tone = aggregatorTone(order.aggregatorName);
  const big = size === "lg" ? "text-4xl sm:text-5xl" : "text-3xl";
  return (
    <div className="min-w-0">
      {label && (
        <span
          className="mb-1 inline-block max-w-full truncate rounded-full border-2 border-ink px-2.5 py-0.5 text-xs font-extrabold uppercase tracking-wide"
          style={{ background: tone.bg, color: tone.fg }}
        >
          {label}
        </span>
      )}
      <div className={`truncate font-mono font-bold leading-tight text-ink ${big}`}>{number}</div>
      {sub && <div className="mt-0.5 break-words font-mono text-sm leading-snug text-muted">{sub}</div>}
    </div>
  );
}
