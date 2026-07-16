// Pure folder-explorer logic, kept out of Explorer.svelte so the
// filtering and cycle-detection rules are unit-testable.

export type FolderEntry = {
  name: string;
  path: string;
  isDir: boolean;
  isSymlink: boolean;
};

export function isHiddenEntry(name: string): boolean {
  return name.startsWith(".");
}

// Hidden files are filtered client-side so toggling the setting never
// re-reads the directory.
export function visibleEntries(entries: FolderEntry[], showHidden: boolean): FolderEntry[] {
  return showHidden ? entries : entries.filter((entry) => !isHiddenEntry(entry.name));
}

// A directory entry is a symlink cycle when its canonical path (what
// the backend resolves symlinks to) already appears among the
// canonical paths of the folders expanded above it. Checked before
// ever fetching its children, so a loop is refused rather than
// walked.
export function isSymlinkCycle(entryPath: string, ancestorPaths: readonly string[]): boolean {
  return ancestorPaths.includes(entryPath);
}

// True when `path` names `ancestorPath` itself or something nested
// under it. Guards drag-and-drop moves: dropping a folder onto itself
// or one of its own descendants would try to make it its own child.
export function isSameOrDescendant(path: string, ancestorPath: string): boolean {
  return path === ancestorPath || path.startsWith(`${ancestorPath}/`);
}

// The destination path for moving `entryPath` (named `entryName`)
// into `targetDirPath` — the join every move/drop uses.
export function destinationPath(targetDirPath: string, entryName: string): string {
  return `${targetDirPath}/${entryName}`;
}

// Callbacks threaded through the explorer tree as one stable object,
// rather than as six separate props at every recursion level.
export type ExplorerActions = {
  onOpenFile: (path: string) => void;
  // Bubbles a completed rename or move up to App.svelte so it can
  // remap the path of any tab open on the affected file (or nested
  // under the affected folder).
  onEntryMoved: (fromPath: string, toEntry: FolderEntry) => void;
  // Bubbles a completed delete up to App.svelte so it can flag any
  // open tab on the deleted file as missing, the same way an external
  // deletion detected by the file watcher already does.
  onEntryDeleted: (path: string) => void;
  onError: (message: string) => void;
  // Invalidates every loaded folder's cached children so a change
  // made anywhere in the tree (create, rename, move, delete) is
  // reflected everywhere it's visible, including the source side of
  // a move.
  onRefreshNeeded: () => void;
  // Asks the tree to open the just-created entry at `path` in rename
  // mode, so a "New File"/"New Folder" action flows straight into
  // naming it.
  onRequestRename: (path: string) => void;
  onRenameConsumed: () => void;
};
