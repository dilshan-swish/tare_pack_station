import {
  TrendingDown,
  Target,
  ShoppingBasket,
  Building2,
  BarChart3,
  Scale,
  CheckCircle2,
  Wrench,
  PackageSearch,
  LineChart,
  Clock,
  SplitSquareHorizontal,
  type LucideIcon,
} from "lucide-react";

// One clean line icon + a soft tinted badge color per question — replaces
// the earlier emoji icons with a treatment that reads as a real product,
// not a chat toy. Colors are drawn from the app's own palette tokens
// (index.css) at reduced opacity, so the badges tint consistently in both
// the question list and history/reports without introducing new colors.
export interface QuestionVisual {
  icon: LucideIcon;
  tint: string; // Tailwind bg-*/text-* pair for the badge
}

export const QUESTION_VISUALS: Record<string, QuestionVisual> = {
  "variance-high": { icon: TrendingDown, tint: "bg-coral/15 text-coral" },
  "variance-low": { icon: Target, tint: "bg-green/15 text-green" },
  basket: { icon: ShoppingBasket, tint: "bg-amber/15 text-[#8a5a10]" },
  "branch-accuracy": { icon: Building2, tint: "bg-green/15 text-green" },
  "branch-variance": { icon: BarChart3, tint: "bg-coral/15 text-coral" },
  "weighed-volume": { icon: Scale, tint: "bg-amber/15 text-[#8a5a10]" },
  "verdict-breakdown": { icon: CheckCircle2, tint: "bg-green/15 text-green" },
  reweigh: { icon: Wrench, tint: "bg-amber/15 text-[#8a5a10]" },
  missed: { icon: PackageSearch, tint: "bg-coral/15 text-coral" },
  trend: { icon: LineChart, tint: "bg-green/15 text-green" },
  hourly: { icon: Clock, tint: "bg-muted/15 text-muted" },
  "branch-outcomes": { icon: SplitSquareHorizontal, tint: "bg-[#4a8bc9]/15 text-[#4a8bc9]" },
};

export const DEFAULT_VISUAL: QuestionVisual = { icon: BarChart3, tint: "bg-muted/15 text-muted" };

export function IconBadge({
  icon: Icon,
  tint,
  size = "md",
}: {
  icon: LucideIcon;
  tint: string;
  size?: "sm" | "md";
}) {
  const box = size === "sm" ? "h-8 w-8" : "h-10 w-10";
  const iconSize = size === "sm" ? 15 : 18;
  return (
    <span className={`flex flex-none items-center justify-center rounded-lg ${box} ${tint}`}>
      <Icon size={iconSize} strokeWidth={2} />
    </span>
  );
}
