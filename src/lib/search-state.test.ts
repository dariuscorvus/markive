import { describe, expect, test } from "vitest";

import {
  appendSearchResult,
  highlightMatch,
  totalMatchCount,
  type SearchFileResult,
} from "./search-state";

function fileResult(path: string, matchCount = 1): SearchFileResult {
  return {
    searchId: "s1",
    path,
    relativePath: path,
    matches: Array.from({ length: matchCount }, (_, i) => ({
      line: i + 1,
      lineText: "some line",
      matchStart: 0,
      matchEnd: 4,
    })),
  };
}

describe("appendSearchResult", () => {
  test("appends a new file's result", () => {
    const results = appendSearchResult([], fileResult("a.md"));
    expect(results.map((r) => r.path)).toEqual(["a.md"]);
  });

  test("appends onto existing results without disturbing them", () => {
    const results = appendSearchResult([fileResult("a.md")], fileResult("b.md"));
    expect(results.map((r) => r.path)).toEqual(["a.md", "b.md"]);
  });

  test("replaces an earlier result for the same path", () => {
    const first = fileResult("a.md", 1);
    const second = fileResult("a.md", 3);
    const results = appendSearchResult([first], second);
    expect(results).toHaveLength(1);
    expect(results[0].matches).toHaveLength(3);
  });
});

describe("highlightMatch", () => {
  test("splits a line into before/match/after segments", () => {
    const segments = highlightMatch("the cat sat", 4, 7);
    expect(segments).toEqual([
      { text: "the ", matched: false },
      { text: "cat", matched: true },
      { text: " sat", matched: false },
    ]);
  });

  test("drops empty segments at the start or end", () => {
    const atStart = highlightMatch("cat sat", 0, 3);
    expect(atStart).toEqual([
      { text: "cat", matched: true },
      { text: " sat", matched: false },
    ]);

    const atEnd = highlightMatch("the cat", 4, 7);
    expect(atEnd).toEqual([
      { text: "the ", matched: false },
      { text: "cat", matched: true },
    ]);
  });

  test("indexes by Unicode code point, matching the backend's char-count offsets", () => {
    // "café🎉x" — the emoji is a surrogate pair in JS but one code
    // point in Rust's char count; a plain string.slice would misalign
    // after it.
    const segments = highlightMatch("café🎉x", 5, 6);
    expect(segments).toEqual([
      { text: "café🎉", matched: false },
      { text: "x", matched: true },
    ]);
  });
});

describe("totalMatchCount", () => {
  test("sums matches across every result", () => {
    const results = [fileResult("a.md", 2), fileResult("b.md", 3)];
    expect(totalMatchCount(results)).toBe(5);
  });

  test("is zero for no results", () => {
    expect(totalMatchCount([])).toBe(0);
  });
});
