// Pure favorites logic, kept out of App.svelte and the sidebar
// components so the tree-building and sorting rules are
// unit-testable.

import { fileName } from "./document-state";

export type FavoriteKind = "file" | "directory";

export type FavoriteEntry = {
  path: string;
  kind: FavoriteKind;
  addedAt: number;
};

// Recent is capped so it stays a quick glance at what's new, not a
// second copy of All.
export const RECENT_LIMIT = 20;

export function isFavorited(favorites: FavoriteEntry[], path: string): boolean {
  return favorites.some((favorite) => favorite.path === path);
}

// Adding an already-favorited path is a no-op — it doesn't bump
// addedAt or move it in Recent, since re-adding isn't a fresh "touch"
// of the item.
export function upsertFavorite(
  favorites: FavoriteEntry[],
  path: string,
  kind: FavoriteKind,
  addedAt: number,
): FavoriteEntry[] {
  if (isFavorited(favorites, path)) return favorites;
  return [...favorites, { path, kind, addedAt }];
}

// Removes only the exact path. A favorited directory's favorited
// descendants (or ancestors) keep their own favorite status
// independently — unfavoriting never cascades.
export function removeFavorite(favorites: FavoriteEntry[], path: string): FavoriteEntry[] {
  return favorites.filter((favorite) => favorite.path !== path);
}

export function sortedAll(favorites: FavoriteEntry[]): FavoriteEntry[] {
  return [...favorites].sort((a, b) => {
    const byName = fileName(a.path).toLowerCase().localeCompare(fileName(b.path).toLowerCase());
    return byName !== 0 ? byName : a.path.localeCompare(b.path);
  });
}

export function sortedRecent(favorites: FavoriteEntry[]): FavoriteEntry[] {
  return [...favorites].sort((a, b) => b.addedAt - a.addedAt).slice(0, RECENT_LIMIT);
}

// The index just past the last path separator, or -1 if `path` has
// none. Index-based, never substring/startsWith, so a sibling whose
// name is a prefix of another's (e.g. "notes" vs "notes2") is never
// mistaken for an ancestor or descendant.
function lastSeparatorIndex(path: string): number {
  return Math.max(path.lastIndexOf("/"), path.lastIndexOf("\\"));
}

// The parent path of `path`, or null once `path` is a filesystem root
// (no separator, or the separator is the very first character). The
// favorites tree stops climbing there rather than merging everything
// under one universal root.
export function parentOf(path: string): string | null {
  const index = lastSeparatorIndex(path);
  if (index <= 0) return null;
  return path.slice(0, index);
}

// Every ancestor path from the top down to (not including) `path`
// itself — used to expand a tree down to a revealed directory.
export function ancestorChain(path: string): string[] {
  const chain: string[] = [];
  let current = parentOf(path);
  while (current !== null) {
    chain.unshift(current);
    current = parentOf(current);
  }
  return chain;
}

export type FavoritesTreeNode = {
  path: string;
  name: string;
  // "directory" for every virtual ancestor and every favorited
  // directory; "file" only for a favorited file, always a leaf.
  kind: "file" | "directory";
  // True only when this exact path is itself a favorite entry — a
  // shared ancestor that was never favorited itself is false.
  isFavorited: boolean;
  addedAt: number | null;
  children: FavoritesTreeNode[];
};

function sortChildren(nodes: FavoritesTreeNode[]): void {
  nodes.sort((a, b) => {
    if (a.kind !== b.kind) return a.kind === "directory" ? -1 : 1;
    return a.name.toLowerCase().localeCompare(b.name.toLowerCase());
  });
  for (const node of nodes) sortChildren(node.children);
}

// Builds the virtual tree from favorited paths alone — no directory
// listing, no live fs reads. Each distinct path resolves to exactly
// one node object (kept in `byPath`), created lazily as a plain
// virtual folder the first time it's referenced as an ancestor; if
// that same path is later (or was earlier) processed as its own
// favorite, `isFavorited`/`kind`/`addedAt` are set on that same
// object. This is what makes a directory that is both favorited and a
// container of favorited descendants (e.g. "notes/" and
// "notes/journal.md") work regardless of insertion order.
export function buildFavoritesTree(favorites: FavoriteEntry[]): FavoritesTreeNode[] {
  const byPath = new Map<string, FavoritesTreeNode>();
  const linkedChildren = new Map<string, Set<string>>();
  const roots: FavoritesTreeNode[] = [];
  const rootPaths = new Set<string>();

  function nodeFor(path: string, kind: "file" | "directory"): FavoritesTreeNode {
    const existing = byPath.get(path);
    if (existing) return existing;
    const created: FavoritesTreeNode = {
      path,
      name: fileName(path),
      kind,
      isFavorited: false,
      addedAt: null,
      children: [],
    };
    byPath.set(path, created);
    return created;
  }

  function link(parent: FavoritesTreeNode, child: FavoritesTreeNode): void {
    let linked = linkedChildren.get(parent.path);
    if (!linked) {
      linked = new Set();
      linkedChildren.set(parent.path, linked);
    }
    if (linked.has(child.path)) return;
    linked.add(child.path);
    parent.children.push(child);
  }

  for (const favorite of favorites) {
    const node = nodeFor(favorite.path, favorite.kind);
    node.isFavorited = true;
    node.kind = favorite.kind;
    node.addedAt = favorite.addedAt;

    let current = node;
    let parentPath = parentOf(favorite.path);
    while (parentPath !== null) {
      const parent = nodeFor(parentPath, "directory");
      link(parent, current);
      current = parent;
      parentPath = parentOf(parentPath);
    }
    if (!rootPaths.has(current.path)) {
      rootPaths.add(current.path);
      roots.push(current);
    }
  }

  sortChildren(roots);
  return roots;
}

// Callbacks threaded through the favorites views as one stable object,
// mirroring ExplorerActions.
export type FavoritesActions = {
  onOpenFile: (path: string) => void;
  onRevealDirectory: (path: string) => void;
  onRemove: (path: string) => void;
};
