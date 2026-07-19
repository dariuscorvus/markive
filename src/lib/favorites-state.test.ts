import { describe, expect, test } from "vitest";

import {
  ancestorChain,
  buildFavoritesTree,
  isFavorited,
  parentOf,
  RECENT_LIMIT,
  removeFavorite,
  sortedAll,
  sortedRecent,
  upsertFavorite,
  type FavoriteEntry,
} from "./favorites-state";

describe("isFavorited", () => {
  test("finds an entry by exact path", () => {
    const favorites: FavoriteEntry[] = [{ path: "/docs/a.md", kind: "file", addedAt: 1 }];
    expect(isFavorited(favorites, "/docs/a.md")).toBe(true);
    expect(isFavorited(favorites, "/docs/b.md")).toBe(false);
  });
});

describe("upsertFavorite", () => {
  test("adds a new favorite", () => {
    const result = upsertFavorite([], "/docs/a.md", "file", 100);
    expect(result).toEqual([{ path: "/docs/a.md", kind: "file", addedAt: 100 }]);
  });

  test("adding an already-favorited path is a no-op", () => {
    const favorites: FavoriteEntry[] = [{ path: "/docs/a.md", kind: "file", addedAt: 100 }];
    const result = upsertFavorite(favorites, "/docs/a.md", "file", 200);
    expect(result).toBe(favorites);
    expect(result).toEqual([{ path: "/docs/a.md", kind: "file", addedAt: 100 }]);
  });
});

describe("removeFavorite", () => {
  test("removes only the exact path", () => {
    const favorites: FavoriteEntry[] = [
      { path: "/docs/notes", kind: "directory", addedAt: 1 },
      { path: "/docs/notes/journal.md", kind: "file", addedAt: 2 },
    ];
    const result = removeFavorite(favorites, "/docs/notes");
    expect(result).toEqual([{ path: "/docs/notes/journal.md", kind: "file", addedAt: 2 }]);
  });

  test("removing an absent path leaves the list unchanged", () => {
    const favorites: FavoriteEntry[] = [{ path: "/docs/a.md", kind: "file", addedAt: 1 }];
    expect(removeFavorite(favorites, "/docs/b.md")).toEqual(favorites);
  });
});

describe("sortedAll", () => {
  test("sorts alphabetically by file name, case-insensitively", () => {
    const favorites: FavoriteEntry[] = [
      { path: "/docs/banana.md", kind: "file", addedAt: 1 },
      { path: "/docs/Apple.md", kind: "file", addedAt: 2 },
      { path: "/docs/cherry.md", kind: "file", addedAt: 3 },
    ];
    expect(sortedAll(favorites).map((entry) => entry.path)).toEqual([
      "/docs/Apple.md",
      "/docs/banana.md",
      "/docs/cherry.md",
    ]);
  });

  test("ties on name are broken by full path", () => {
    const favorites: FavoriteEntry[] = [
      { path: "/z/a.md", kind: "file", addedAt: 1 },
      { path: "/a/a.md", kind: "file", addedAt: 2 },
    ];
    expect(sortedAll(favorites).map((entry) => entry.path)).toEqual(["/a/a.md", "/z/a.md"]);
  });
});

describe("sortedRecent", () => {
  test("sorts by addedAt descending", () => {
    const favorites: FavoriteEntry[] = [
      { path: "/docs/old.md", kind: "file", addedAt: 1 },
      { path: "/docs/new.md", kind: "file", addedAt: 3 },
      { path: "/docs/mid.md", kind: "file", addedAt: 2 },
    ];
    expect(sortedRecent(favorites).map((entry) => entry.path)).toEqual([
      "/docs/new.md",
      "/docs/mid.md",
      "/docs/old.md",
    ]);
  });

  test("caps the result at RECENT_LIMIT", () => {
    const favorites: FavoriteEntry[] = Array.from({ length: RECENT_LIMIT + 5 }, (_, index) => ({
      path: `/docs/${index}.md`,
      kind: "file" as const,
      addedAt: index,
    }));
    expect(sortedRecent(favorites)).toHaveLength(RECENT_LIMIT);
  });
});

describe("parentOf", () => {
  test("returns the parent directory for both separators", () => {
    expect(parentOf("/docs/notes/a.md")).toBe("/docs/notes");
    expect(parentOf("C:\\docs\\a.md")).toBe("C:\\docs");
  });

  test("stops at a filesystem root", () => {
    expect(parentOf("/docs")).toBe(null);
    expect(parentOf("C:\\docs")).toBe("C:");
    expect(parentOf("C:")).toBe(null);
  });
});

describe("ancestorChain", () => {
  test("returns every ancestor from the top down", () => {
    expect(ancestorChain("/docs/notes/deep/a.md")).toEqual(["/docs", "/docs/notes", "/docs/notes/deep"]);
  });

  test("is empty for a root-level path", () => {
    expect(ancestorChain("/docs")).toEqual([]);
  });
});

describe("buildFavoritesTree", () => {
  test("a single favorite produces one root chain with only the leaf marked favorited", () => {
    const tree = buildFavoritesTree([{ path: "/docs/notes/a.md", kind: "file", addedAt: 1 }]);
    expect(tree).toHaveLength(1);
    expect(tree[0]).toMatchObject({ path: "/docs", isFavorited: false });
    expect(tree[0].children).toHaveLength(1);
    expect(tree[0].children[0]).toMatchObject({ path: "/docs/notes", isFavorited: false });
    expect(tree[0].children[0].children).toHaveLength(1);
    expect(tree[0].children[0].children[0]).toMatchObject({
      path: "/docs/notes/a.md",
      isFavorited: true,
      kind: "file",
      addedAt: 1,
    });
  });

  test("two favorites sharing an ancestor merge into one shared node", () => {
    const tree = buildFavoritesTree([
      { path: "/docs/notes/a.md", kind: "file", addedAt: 1 },
      { path: "/docs/notes/b.md", kind: "file", addedAt: 2 },
    ]);
    expect(tree).toHaveLength(1);
    const notes = tree[0].children[0];
    expect(notes).toMatchObject({ path: "/docs/notes", isFavorited: false });
    expect(notes.children.map((child) => child.path)).toEqual(["/docs/notes/a.md", "/docs/notes/b.md"]);
  });

  test("a directory favorited alongside a file inside it — insertion order: directory then file", () => {
    const tree = buildFavoritesTree([
      { path: "/docs/notes", kind: "directory", addedAt: 1 },
      { path: "/docs/notes/journal.md", kind: "file", addedAt: 2 },
    ]);
    const notes = tree[0].children[0];
    expect(notes).toMatchObject({ path: "/docs/notes", isFavorited: true, kind: "directory", addedAt: 1 });
    expect(notes.children).toHaveLength(1);
    expect(notes.children[0]).toMatchObject({ path: "/docs/notes/journal.md", isFavorited: true });
  });

  test("a directory favorited alongside a file inside it — insertion order: file then directory", () => {
    const tree = buildFavoritesTree([
      { path: "/docs/notes/journal.md", kind: "file", addedAt: 2 },
      { path: "/docs/notes", kind: "directory", addedAt: 1 },
    ]);
    const notes = tree[0].children[0];
    expect(notes).toMatchObject({ path: "/docs/notes", isFavorited: true, kind: "directory", addedAt: 1 });
    expect(notes.children).toHaveLength(1);
    expect(notes.children[0]).toMatchObject({ path: "/docs/notes/journal.md", isFavorited: true });
  });

  test("two unrelated favorites produce two independent roots, not merged", () => {
    const tree = buildFavoritesTree([
      { path: "/docs/a.md", kind: "file", addedAt: 1 },
      { path: "/projects/b.md", kind: "file", addedAt: 2 },
    ]);
    expect(tree.map((node) => node.path).sort()).toEqual(["/docs", "/projects"]);
  });

  test("a sibling whose name is a prefix of another's is not treated as its ancestor", () => {
    const tree = buildFavoritesTree([
      { path: "/docs/notes/a.md", kind: "file", addedAt: 1 },
      { path: "/docs/notes2/b.md", kind: "file", addedAt: 2 },
    ]);
    const docs = tree[0];
    expect(docs.children.map((child) => child.path).sort()).toEqual(["/docs/notes", "/docs/notes2"]);
  });

  test("children are sorted directories-first, then case-insensitively by name", () => {
    const tree = buildFavoritesTree([
      { path: "/docs/zeta.md", kind: "file", addedAt: 1 },
      { path: "/docs/Alpha", kind: "directory", addedAt: 2 },
      { path: "/docs/beta.md", kind: "file", addedAt: 3 },
    ]);
    expect(tree[0].children.map((child) => child.name)).toEqual(["Alpha", "beta.md", "zeta.md"]);
  });
});
