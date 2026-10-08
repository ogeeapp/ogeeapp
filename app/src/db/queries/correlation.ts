export const CORRELATION_MIN_OVERLAP = 20;

export type CorrelationDays = 7 | 30;

export interface HourlySpotRow {
  market_id: number;
  t: number;
  spot: string;
}

export interface PearsonResult {
  value: number | null;
  overlap: number;
}

export interface CorrelationMatrix {
  values: (number | null)[][];
  overlap: number[][];
}

/** Build hourly log returns only across adjacent buckets for the same market. */
export function hourlyReturns(rows: HourlySpotRow[]): Map<number, Map<number, number>> {
  const spotsByMarket = new Map<number, Map<number, number>>();

  for (const row of rows) {
    const marketId = Number(row.market_id);
    const t = Number(row.t);
    const spot = Number(row.spot);
    if (!Number.isFinite(marketId) || !Number.isFinite(t) || !Number.isFinite(spot) || spot <= 0) continue;

    let spots = spotsByMarket.get(marketId);
    if (!spots) {
      spots = new Map();
      spotsByMarket.set(marketId, spots);
    }
    spots.set(t, spot);
  }

  const returnsByMarket = new Map<number, Map<number, number>>();
  for (const [marketId, spots] of spotsByMarket) {
    const returns = new Map<number, number>();
    for (const [t, spot] of spots) {
      const previous = spots.get(t - 3_600);
      if (previous === undefined || previous <= 0) continue;
      const value = Math.log(spot / previous);
      if (Number.isFinite(value)) returns.set(t, value);
    }
    returnsByMarket.set(marketId, returns);
  }
  return returnsByMarket;
}

/** Pearson correlation over timestamps shared by both return series. */
export function pearson(a: Map<number, number>, b: Map<number, number>): PearsonResult {
  const pairs: Array<[number, number]> = [];
  for (const [t, left] of a) {
    const right = b.get(t);
    if (right !== undefined && Number.isFinite(left) && Number.isFinite(right)) pairs.push([left, right]);
  }

  const overlap = pairs.length;
  if (overlap < CORRELATION_MIN_OVERLAP) return { value: null, overlap };

  const meanA = pairs.reduce((sum, [left]) => sum + left, 0) / overlap;
  const meanB = pairs.reduce((sum, [, right]) => sum + right, 0) / overlap;
  let covariance = 0;
  let varianceA = 0;
  let varianceB = 0;
  for (const [left, right] of pairs) {
    const deltaA = left - meanA;
    const deltaB = right - meanB;
    covariance += deltaA * deltaB;
    varianceA += deltaA * deltaA;
    varianceB += deltaB * deltaB;
  }

  const denominator = Math.sqrt(varianceA * varianceB);
  if (varianceA === 0 || varianceB === 0 || !Number.isFinite(denominator) || denominator === 0) {
    return { value: null, overlap };
  }
  const value = covariance / denominator;
  if (!Number.isFinite(value)) return { value: null, overlap };
  const clamped = Math.max(-1, Math.min(1, value));
  return { value: Math.round(clamped * 10_000) / 10_000, overlap };
}

/** Assemble a symmetric matrix in the same order as the supplied symbols. */
export function correlationMatrix(
  symbols: string[],
  returnsById: Map<number, Map<number, number>>,
  ids: number[],
): CorrelationMatrix {
  const values = symbols.map(() => symbols.map(() => null as number | null));
  const overlap = symbols.map(() => symbols.map(() => 0));

  for (let i = 0; i < symbols.length; i++) {
    const own = returnsById.get(ids[i]!)?.size ?? 0;
    values[i]![i] = 1;
    overlap[i]![i] = own;
    for (let j = i + 1; j < symbols.length; j++) {
      const result = pearson(
        returnsById.get(ids[i]!) ?? new Map(),
        returnsById.get(ids[j]!) ?? new Map(),
      );
      values[i]![j] = result.value;
      values[j]![i] = result.value;
      overlap[i]![j] = result.overlap;
      overlap[j]![i] = result.overlap;
    }
  }

  return { values, overlap };
}
