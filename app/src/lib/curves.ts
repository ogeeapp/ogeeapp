const round = (value: number, digits: number): number => {
  const factor = 10 ** digits;
  return Math.round(value * factor) / factor;
};

export const CURVE_EXPONENTS = { squared: 2, cubed: 3, root: 0.5, downside: -1 } as const;
export type TradableCurve = keyof typeof CURVE_EXPONENTS;
export const CURVE_ORDER: TradableCurve[] = ["squared", "cubed", "root", "downside"];
export const CURVE_NOTATION: Record<TradableCurve, string> = {
  squared: "²",
  cubed: "³",
  root: "^½",
  downside: "⁻¹",
};

/** Index change for an instant underlying move, with both values expressed in percent. */
export function curvePayoffPct(exponent: number, movePct: number): number | null {
  if (!Number.isFinite(exponent) || !Number.isFinite(movePct) || movePct <= -100) return null;
  const payoff = (Math.pow(1 + movePct / 100, exponent) - 1) * 100;
  return Number.isFinite(payoff) ? round(payoff, 4) : null;
}

/** Fair annual carry from the volatility term only. Positive values mean holders pay. */
export function fairCarryAnnual(exponent: number, sigmaAnnual: number): number | null {
  if (!Number.isFinite(exponent) || !Number.isFinite(sigmaAnnual) || sigmaAnnual < 0) return null;
  return 0.5 * exponent * (exponent - 1) * sigmaAnnual ** 2;
}

/** Fair daily carry, expressed as a percent. */
export function fairCarryDailyPct(exponent: number, sigmaAnnual: number): number | null {
  const annual = fairCarryAnnual(exponent, sigmaAnnual);
  return annual === null ? null : round(annual / 365 * 100, 5);
}

/** Recover annualized volatility from the volatility-only fair carry term. */
export function sigmaFromCarry(exponent: number, carryAnnual: number): number | null {
  if (!Number.isFinite(exponent) || !Number.isFinite(carryAnnual)) return null;
  const coefficient = 0.5 * exponent * (exponent - 1);
  if (coefficient === 0) return null;
  const variance = carryAnnual / coefficient;
  return variance < 0 ? null : Math.sqrt(variance);
}
