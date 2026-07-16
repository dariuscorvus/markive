import { describe, expect, test } from "vitest";

import {
  findTabByPath,
  isTabDirty,
  moveTab,
  nextActiveTabId,
  tabTitle,
  type Tab,
} from "./tab-state";

function makeTab(overrides: Partial<Tab> = {}): Tab {
  return {
    id: "a",
    source: { kind: "untitled" },
    sourceText: "",
    savedText: null,
    viewMode: "rendered",
    renderedHtml: "",
    scroll: { rendered: 0, source: 0 },
    conflict: null,
    ...overrides,
  };
}

describe("isTabDirty", () => {
  test("delegates to isDocumentDirty via source/sourceText/savedText", () => {
    const clean = makeTab({
      source: { kind: "file", path: "/a.md" },
      sourceText: "x",
      savedText: "x",
    });
    const dirty = makeTab({
      source: { kind: "file", path: "/a.md" },
      sourceText: "x edited",
      savedText: "x",
    });
    expect(isTabDirty(clean)).toBe(false);
    expect(isTabDirty(dirty)).toBe(true);
  });
});

describe("tabTitle", () => {
  test("file tabs show the filename", () => {
    expect(tabTitle(makeTab({ source: { kind: "file", path: "/docs/a.md" } }))).toBe("a.md");
  });

  test("pathless tabs show a fixed label", () => {
    expect(tabTitle(makeTab({ source: { kind: "clipboard" } }))).toBe("Clipboard");
    expect(tabTitle(makeTab({ source: { kind: "stdin" } }))).toBe("stdin");
    expect(tabTitle(makeTab({ source: { kind: "untitled" } }))).toBe("Untitled");
  });
});

describe("findTabByPath", () => {
  test("finds a file tab by exact path", () => {
    const tabs = [
      makeTab({ id: "1", source: { kind: "file", path: "/a.md" } }),
      makeTab({ id: "2", source: { kind: "untitled" } }),
    ];
    expect(findTabByPath(tabs, "/a.md")?.id).toBe("1");
    expect(findTabByPath(tabs, "/missing.md")).toBeUndefined();
  });
});

describe("nextActiveTabId", () => {
  const tabs = [makeTab({ id: "1" }), makeTab({ id: "2" }), makeTab({ id: "3" })];

  test("prefers the tab that shifts into the closed tab's slot", () => {
    expect(nextActiveTabId(tabs, "1")).toBe("2");
    expect(nextActiveTabId(tabs, "2")).toBe("3");
  });

  test("falls back to the new last tab when the last tab closes", () => {
    expect(nextActiveTabId(tabs, "3")).toBe("2");
  });

  test("returns null when closing the only tab", () => {
    expect(nextActiveTabId([makeTab({ id: "only" })], "only")).toBeNull();
  });

  test("returns null for an unknown id", () => {
    expect(nextActiveTabId(tabs, "missing")).toBeNull();
  });
});

describe("moveTab", () => {
  test("reorders an item to a later index", () => {
    expect(moveTab(["a", "b", "c"], 0, 2)).toEqual(["b", "c", "a"]);
  });

  test("reorders an item to an earlier index", () => {
    expect(moveTab(["a", "b", "c"], 2, 0)).toEqual(["c", "a", "b"]);
  });

  test("is a no-op for equal or out-of-range indices", () => {
    expect(moveTab(["a", "b"], 1, 1)).toEqual(["a", "b"]);
    expect(moveTab(["a", "b"], -1, 0)).toEqual(["a", "b"]);
    expect(moveTab(["a", "b"], 0, 5)).toEqual(["a", "b"]);
  });
});
