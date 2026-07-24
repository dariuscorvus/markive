import { describe, expect, test } from "vitest";

import {
  destinationPath,
  isHiddenEntry,
  isSameOrDescendant,
  isSymlinkCycle,
  refreshDecision,
  visibleEntries,
  type FolderEntry,
} from "./folder-state";

function entry(name: string, overrides: Partial<FolderEntry> = {}): FolderEntry {
  return { name, path: `/root/${name}`, isDir: false, isSymlink: false, ...overrides };
}

describe("isHiddenEntry", () => {
  test("names starting with a dot are hidden", () => {
    expect(isHiddenEntry(".obsidian")).toBe(true);
    expect(isHiddenEntry(".gitignore")).toBe(true);
  });

  test("ordinary names are not hidden", () => {
    expect(isHiddenEntry("notes.md")).toBe(false);
  });
});

describe("visibleEntries", () => {
  const entries = [entry("notes.md"), entry(".obsidian", { isDir: true }), entry(".hidden.md")];

  test("hides dotfiles by default", () => {
    const visible = visibleEntries(entries, false);
    expect(visible.map((e) => e.name)).toEqual(["notes.md"]);
  });

  test("shows dotfiles when requested", () => {
    const visible = visibleEntries(entries, true);
    expect(visible.map((e) => e.name)).toEqual(["notes.md", ".obsidian", ".hidden.md"]);
  });
});

describe("isSymlinkCycle", () => {
  test("a path already among the ancestor chain is a cycle", () => {
    expect(isSymlinkCycle("/root/a", ["/root", "/root/a"])).toBe(true);
  });

  test("a path not in the ancestor chain is not a cycle", () => {
    expect(isSymlinkCycle("/root/b", ["/root", "/root/a"])).toBe(false);
  });

  test("an empty ancestor chain has no cycle", () => {
    expect(isSymlinkCycle("/root", [])).toBe(false);
  });
});

describe("isSameOrDescendant", () => {
  test("a path equal to the ancestor is itself", () => {
    expect(isSameOrDescendant("/root/a", "/root/a")).toBe(true);
  });

  test("a path nested under the ancestor is a descendant", () => {
    expect(isSameOrDescendant("/root/a/b/c.md", "/root/a")).toBe(true);
  });

  test("an unrelated path is not", () => {
    expect(isSameOrDescendant("/root/b", "/root/a")).toBe(false);
  });

  test("a sibling whose name is a string prefix is not a false positive", () => {
    expect(isSameOrDescendant("/root/a-extra/c.md", "/root/a")).toBe(false);
  });
});

describe("destinationPath", () => {
  test("joins the target directory and entry name", () => {
    expect(destinationPath("/root/sub", "note.md")).toBe("/root/sub/note.md");
  });
});

describe("refreshDecision", () => {
  test("a node with no loaded children has nothing to invalidate", () => {
    expect(refreshDecision(false, false)).toEqual({ resetChildren: false, reload: false });
    expect(refreshDecision(false, true)).toEqual({ resetChildren: false, reload: false });
  });

  test("a collapsed node with cached children discards the cache without reloading", () => {
    expect(refreshDecision(true, false)).toEqual({ resetChildren: true, reload: false });
  });

  test("an expanded node with cached children invalidates and reloads", () => {
    expect(refreshDecision(true, true)).toEqual({ resetChildren: true, reload: true });
  });
});
