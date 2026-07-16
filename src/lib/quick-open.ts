// Pure Quick Open logic, kept out of the component so fuzzy matching
// and ranking are unit-testable.

import { isMarkdownPath } from "./document-state";

export type QuickOpenEntry = {
  name: string;
  path: string;
  relativePath: string;
};

// A flat subsequence fuzzy score: every character of `query` must
// appear in order somewhere in `candidate`. Higher is better; null
// means no match. Contiguous runs score more than scattered
// characters, and a run starting earlier in the string scores more
// than one starting later — the usual "Sublime Text"-style fuzzy
// ranking shape, kept intentionally simple.
export function fuzzyScore(query: string, candidate: string): number | null {
  if (query.length === 0) return 0;

  const q = query.toLowerCase();
  const c = candidate.toLowerCase();

  let score = 0;
  let searchFrom = 0;
  let consecutive = 0;

  for (const char of q) {
    const foundAt = c.indexOf(char, searchFrom);
    if (foundAt === -1) return null;

    consecutive = foundAt === searchFrom ? consecutive + 1 : 1;
    score += consecutive * 2 - (foundAt - searchFrom);
    searchFrom = foundAt + 1;
  }

  return score - c.indexOf(q[0]);
}

// Markdown files rank above equally-matching non-Markdown files —
// added after the fuzzy score so it never outweighs an actual better
// text match, just breaks ties (and near-ties) toward Markdown.
const MARKDOWN_BONUS = 1000;

// Ranks `entries` against `query`, Markdown-first, and returns the
// top `limit`. An empty query returns Markdown files first, then
// alphabetically, so the palette isn't blank the moment it opens.
export function searchQuickOpenEntries(
  entries: readonly QuickOpenEntry[],
  query: string,
  limit = 50,
): QuickOpenEntry[] {
  const trimmed = query.trim();

  if (!trimmed) {
    return [...entries]
      .sort((a, b) => {
        const markdownDiff = Number(isMarkdownPath(b.path)) - Number(isMarkdownPath(a.path));
        return markdownDiff !== 0 ? markdownDiff : a.relativePath.localeCompare(b.relativePath);
      })
      .slice(0, limit);
  }

  const scored: { entry: QuickOpenEntry; score: number }[] = [];
  for (const entry of entries) {
    const score = fuzzyScore(trimmed, entry.relativePath);
    if (score === null) continue;
    scored.push({ entry, score: score + (isMarkdownPath(entry.path) ? MARKDOWN_BONUS : 0) });
  }

  scored.sort((a, b) => b.score - a.score || a.entry.relativePath.localeCompare(b.entry.relativePath));
  return scored.slice(0, limit).map((match) => match.entry);
}
