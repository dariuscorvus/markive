// Pure full-text-search logic, kept out of the component so result
// accumulation and match highlighting are unit-testable.

export type SearchMatch = {
  line: number;
  lineText: string;
  matchStart: number;
  matchEnd: number;
};

export type SearchFileResult = {
  searchId: string;
  path: string;
  relativePath: string;
  matches: SearchMatch[];
};

// Appends an incoming file result to the accumulated list, replacing
// any earlier result for the same path — a file can only stream in
// once per search, but this keeps the merge well-defined if a
// backend change ever changes that.
export function appendSearchResult(
  results: readonly SearchFileResult[],
  incoming: SearchFileResult,
): SearchFileResult[] {
  const withoutExisting = results.filter((result) => result.path !== incoming.path);
  return [...withoutExisting, incoming];
}

export type LineSegment = { text: string; matched: boolean };

// Splits a line into before/match/after segments for rendering, using
// the search backend's character-count offsets. Iterates the line as
// Unicode code points (not UTF-16 code units), matching how the
// offsets were computed on the Rust side — plain string slicing would
// misalign on a line containing astral characters (most emoji).
export function highlightMatch(lineText: string, matchStart: number, matchEnd: number): LineSegment[] {
  const chars = Array.from(lineText);
  const segments: LineSegment[] = [
    { text: chars.slice(0, matchStart).join(""), matched: false },
    { text: chars.slice(matchStart, matchEnd).join(""), matched: true },
    { text: chars.slice(matchEnd).join(""), matched: false },
  ];
  return segments.filter((segment) => segment.text.length > 0);
}

export function totalMatchCount(results: readonly SearchFileResult[]): number {
  return results.reduce((sum, result) => sum + result.matches.length, 0);
}
