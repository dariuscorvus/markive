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
