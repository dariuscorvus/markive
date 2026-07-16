// Pure tab-state logic, kept out of App.svelte so dirty rules, path
// matching, and reorder/close-focus rules are unit-testable.

import { fileName, isDocumentDirty, type DocumentSource } from "./document-state";

export type ViewMode = "rendered" | "source" | "split";
export type ScrollPosition = { rendered: number; source: number };

export type Tab = {
  id: string;
  source: DocumentSource;
  sourceText: string;
  // Content as last loaded or saved; null for documents that never
  // had a file (clipboard, stdin, untitled), which stay dirty until
  // saved.
  savedText: string | null;
  viewMode: ViewMode;
  renderedHtml: string;
  scroll: ScrollPosition;
  // External file state for this tab: the disk copy changed under
  // local edits, or the file disappeared.
  conflict: "conflict" | "missing" | null;
};

export function isTabDirty(tab: Tab): boolean {
  return isDocumentDirty(tab.source, tab.sourceText, tab.savedText);
}

export function tabTitle(tab: Tab): string {
  switch (tab.source.kind) {
    case "file":
      return fileName(tab.source.path);
    case "clipboard":
      return "Clipboard";
    case "stdin":
      return "stdin";
    case "untitled":
      return "Untitled";
  }
}

export function findTabByPath(tabs: readonly Tab[], path: string): Tab | undefined {
  return tabs.find((tab) => tab.source.kind === "file" && tab.source.path === path);
}

// Which tab should become active after closing `closingId`, given the
// tabs as they were before the close. Prefers the tab that was
// immediately to the right, then the one to the left, then none.
export function nextActiveTabId(tabs: readonly Tab[], closingId: string): string | null {
  const index = tabs.findIndex((tab) => tab.id === closingId);
  if (index === -1) return null;

  const remaining = tabs.filter((tab) => tab.id !== closingId);
  if (remaining.length === 0) return null;

  return remaining[Math.min(index, remaining.length - 1)].id;
}

// Moves the item at `fromIndex` to `toIndex`, preserving every other
// item's relative order. Used for drag-to-reorder in the tab strip.
export function moveTab<T>(items: readonly T[], fromIndex: number, toIndex: number): T[] {
  if (
    fromIndex === toIndex ||
    fromIndex < 0 ||
    toIndex < 0 ||
    fromIndex >= items.length ||
    toIndex >= items.length
  ) {
    return [...items];
  }

  const next = [...items];
  const [moved] = next.splice(fromIndex, 1);
  next.splice(toIndex, 0, moved);
  return next;
}
