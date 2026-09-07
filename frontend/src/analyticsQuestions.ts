// Every predefined analytics question, shared across the Ask page (question
// list), History and Reports (icon/label lookups by id). Each maps to one
// server-side computation in AnalyticsController.cs — there's no free-text
// input and no live model call; "shortLabel" is what the list shows,
// "description" is the one-line subtitle, and "question" is the full
// wording shown once a question has actually been asked.
export interface QuestionDef {
  id: string;
  shortLabel: string;
  description: string;
  question: string;
  endpoint: string;
  extraParams?: Record<string, string>;
}

export const QUESTIONS: QuestionDef[] = [
  {
    id: "variance-high",
    shortLabel: "Most inconsistent orders",
    description: "Orders with the highest inconsistencies",
    question: "What item orders showed the most variance?",
    endpoint: "order-consistency",
    extraParams: { mode: "high" },
  },
  {
    id: "variance-low",
    shortLabel: "Most accurate orders",
    description: "Orders with the highest accuracy",
    question: "Which items in orders show near accuracy?",
    endpoint: "order-consistency",
    extraParams: { mode: "low" },
  },
  {
    id: "basket",
    shortLabel: "What's bought together",
    description: "Frequently ordered items together",
    question: "Market basket analysis — which items are most often ordered together?",
    endpoint: "market-basket",
  },
  {
    id: "branch-accuracy",
    shortLabel: "Most accurate branch",
    description: "Branch with the highest accuracy",
    question: "Which brand/branch has the most close-to-accurate weights for orders?",
    endpoint: "branch-accuracy",
  },
  {
    id: "branch-variance",
    shortLabel: "Least consistent branch",
    description: "Branch with the lowest consistency",
    question: "Which branch has the highest variance?",
    endpoint: "branch-variance",
  },
  {
    id: "weighed-volume",
    shortLabel: "Weighed order volume",
    description: "Total volume of weighed orders",
    question: "Which brand/branch has a higher weighed-to-total-orders ratio?",
    endpoint: "weighed-volume",
  },
  {
    id: "verdict-breakdown",
    shortLabel: "Saved vs. correct orders",
    description: "Orders saved that were off weight",
    question:
      "How many correctly weighed orders? How many missing orders saved, how many mixed-up orders saved?",
    endpoint: "verdict-breakdown",
  },
  {
    id: "reweigh",
    shortLabel: "Items needing recalibration",
    description: "Items/modifiers needing recalibration",
    question: "Which items may need a more accurate reweigh for the item and its modifiers?",
    endpoint: "reweigh-candidates",
  },
  {
    id: "missed",
    shortLabel: "Most often left off",
    description: "Most frequently left-off items",
    question: "What items are most likely getting missed?",
    endpoint: "missed-items",
  },
  {
    id: "trend",
    shortLabel: "Accuracy over time",
    description: "Accuracy trend over time",
    question: "How has on-weight accuracy trended over time?",
    endpoint: "accuracy-trend",
  },
  {
    id: "hourly",
    shortLabel: "Off-weight by hour",
    description: "Off-weight trends by hour",
    question: "What time of day do most off-weight orders happen?",
    endpoint: "hourly-pattern",
  },
  {
    id: "branch-outcomes",
    shortLabel: "Outcomes by branch",
    description: "On/under/over split per branch",
    question: "How do on-weight, under, and over outcomes break down by branch?",
    endpoint: "branch-outcomes",
  },
];

export function findQuestion(id: string): QuestionDef | undefined {
  return QUESTIONS.find((q) => q.id === id);
}
