import { expect, test } from "bun:test";
import { correlationMatrix, hourlyReturns, pearson } from "./correlation";

const spots = (market_id: number, values: Array<[number, number]>) =>
  values.map(([t, spot]) => ({ market_id, t, spot: String(spot) }));

test("hourly returns use only exactly adjacent hourly buckets", () => {
  const result = hourlyReturns(spots(1, [[0, 100], [3_600, 101], [7_200, 102]]));
  expect([...result.get(1)!.keys()]).toEqual([3_600, 7_200]);
  expect(result.get(1)!.get(3_600)).toBeCloseTo(Math.log(101 / 100));
  expect(result.get(1)!.get(7_200)).toBeCloseTo(Math.log(102 / 101));
});

test("hourly returns skip missing buckets instead of joining across gaps", () => {
  const result = hourlyReturns(spots(1, [[0, 100], [3_600, 101], [18_000, 110]]));
  expect([...result.get(1)!.keys()]).toEqual([3_600]);
  expect(result.get(1)!.has(18_000)).toBe(false);
});

test("zero and negative spots invalidate returns touching those buckets", () => {
  const result = hourlyReturns(spots(1, [[0, 100], [3_600, 0], [7_200, 102], [10_800, 103], [14_400, -1], [18_000, 105]]));
  expect([...result.get(1)!.keys()]).toEqual([10_800]);
});

test("Pearson correlation handles identical and opposite series", () => {
  const a = new Map(Array.from({ length: 25 }, (_, i) => [i, i + 1]));
  const same = new Map(a);
  const opposite = new Map([...a].map(([t, value]) => [t, -value]));
  expect(pearson(a, same)).toEqual({ value: 1, overlap: 25 });
  expect(pearson(a, opposite)).toEqual({ value: -1, overlap: 25 });
});

test("Pearson correlation reports insufficient overlap and zero variance", () => {
  const a = new Map(Array.from({ length: 19 }, (_, i) => [i, i + 1]));
  expect(pearson(a, new Map(a))).toEqual({ value: null, overlap: 19 });

  const constant = new Map(Array.from({ length: 25 }, (_, i) => [i, 1]));
  const changing = new Map(Array.from({ length: 25 }, (_, i) => [i, i + 1]));
  expect(pearson(constant, changing)).toEqual({ value: null, overlap: 25 });
});

test("correlation matrix is symmetric and diagonals retain their own return counts", () => {
  const a = new Map(Array.from({ length: 25 }, (_, i) => [i, i + 1]));
  const b = new Map([...a].map(([t, value]) => [t, value * -2]));
  const matrix = correlationMatrix(["A", "B"], new Map([[11, a], [12, b]]), [11, 12]);

  expect(matrix.values).toEqual([[1, -1], [-1, 1]]);
  expect(matrix.overlap).toEqual([[25, 25], [25, 25]]);
});
