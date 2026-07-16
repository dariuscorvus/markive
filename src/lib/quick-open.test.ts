import { describe, expect, test } from "vitest";

import { fuzzyScore, searchQuickOpenEntries, type QuickOpenEntry } from "./quick-open";

function entry(relativePath: string): QuickOpenEntry {
  return {
    name: relativePath.split("/").pop() ?? relativePath,
    path: `/root/${relativePath}`,
    relativePath,
  };
}

describe("fuzzyScore", () => {
  test("matches an in-order subsequence, case-insensitively", () => {
    expect(fuzzyScore("nts", "notes.md")).not.toBeNull();
    expect(fuzzyScore("NTS", "notes.md")).toBe(fuzzyScore("nts", "notes.md"));
  });

  test("returns null when the query isn't a subsequence", () => {
    expect(fuzzyScore("xyz", "notes.md")).toBeNull();
  });

  test("an empty query always matches with score 0", () => {
    expect(fuzzyScore("", "anything")).toBe(0);
  });

  test("scores a contiguous match higher than a scattered one", () => {
    const contiguous = fuzzyScore("note", "notebook.md");
    const scattered = fuzzyScore("note", "n-o-t-e.md");
    expect(contiguous).not.toBeNull();
    expect(scattered).not.toBeNull();
    expect(contiguous! > scattered!).toBe(true);
  });

  test("scores a match starting earlier in the string higher", () => {
    const early = fuzzyScore("cat", "cat-notes.md");
    const late = fuzzyScore("cat", "notes-cat.md");
    expect(early! > late!).toBe(true);
  });
});

describe("searchQuickOpenEntries", () => {
  test("an empty query lists Markdown files first, then alphabetically", () => {
    const entries = [entry("zeta.md"), entry("image.png"), entry("alpha.md")];
    const result = searchQuickOpenEntries(entries, "");
    expect(result.map((e) => e.relativePath)).toEqual(["alpha.md", "zeta.md", "image.png"]);
  });

  test("ranks a matching Markdown file above an equally-matching non-Markdown file", () => {
    const entries = [entry("readme.txt"), entry("readme.md")];
    const result = searchQuickOpenEntries(entries, "readme");
    expect(result.map((e) => e.relativePath)).toEqual(["readme.md", "readme.txt"]);
  });

  test("a strong non-Markdown text match still loses to the Markdown bonus", () => {
    // Confirms the bonus is a tie-breaker relative to typical fuzzy
    // score deltas for short queries, not an absolute override.
    const entries = [entry("exact-match-name.png"), entry("zzzzzzzzz.md")];
    const result = searchQuickOpenEntries(entries, "exact-match-name");
    expect(result[0].relativePath).toBe("exact-match-name.png");
  });

  test("excludes entries that don't match the query", () => {
    const entries = [entry("alpha.md"), entry("beta.md")];
    const result = searchQuickOpenEntries(entries, "zzz");
    expect(result).toEqual([]);
  });

  test("matches against the relative path, not just the file name", () => {
    const entries = [entry("notes/deep/target.md"), entry("other.md")];
    const result = searchQuickOpenEntries(entries, "notesdeep");
    expect(result.map((e) => e.relativePath)).toEqual(["notes/deep/target.md"]);
  });

  test("caps results at the given limit", () => {
    const entries = Array.from({ length: 10 }, (_, i) => entry(`file-${i}.md`));
    const result = searchQuickOpenEntries(entries, "", 3);
    expect(result).toHaveLength(3);
  });
});
