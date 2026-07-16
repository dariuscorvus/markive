<script lang="ts">
  import { FileWarning } from "@lucide/svelte";
  import { invoke } from "@tauri-apps/api/core";

  import {
    destinationPath,
    visibleEntries,
    type ExplorerActions,
    type FolderEntry,
  } from "$lib/folder-state";
  import ExplorerNode from "./ExplorerNode.svelte";

  let {
    rootPath,
    showHidden,
    activePath,
    isActiveDirty,
    onOpenFile,
    onEntryMoved,
    onEntryDeleted,
    onError,
  }: {
    rootPath: string;
    showHidden: boolean;
    activePath: string | null;
    isActiveDirty: boolean;
    onOpenFile: (path: string) => void;
    onEntryMoved: (fromPath: string, toEntry: FolderEntry) => void;
    onEntryDeleted: (path: string) => void;
    onError: (message: string) => void;
  } = $props();

  let entries = $state<FolderEntry[] | null>(null);
  let error = $state<string | null>(null);
  let refreshToken = $state(0);
  let pendingRenamePath = $state<string | null>(null);

  async function load(path: string) {
    entries = null;
    error = null;
    try {
      entries = await invoke<FolderEntry[]>("read_folder_entries", { path });
    } catch (loadError) {
      error = loadError instanceof Error ? loadError.message : String(loadError);
    }
  }

  // The root's own children load eagerly — only nested folders are
  // lazy — so the sidebar isn't empty the moment a folder opens. Also
  // reloads whenever anything changes anywhere in the tree.
  $effect(() => {
    void [rootPath, refreshToken];
    void load(rootPath);
  });

  let visible = $derived(entries ? visibleEntries(entries, showHidden) : []);

  let actions: ExplorerActions = $derived({
    onOpenFile,
    onEntryMoved,
    onEntryDeleted,
    onError,
    onRefreshNeeded: () => {
      refreshToken += 1;
    },
    onRequestRename: (path) => {
      pendingRenamePath = path;
    },
    onRenameConsumed: () => {
      pendingRenamePath = null;
    },
  });

  /** Creates a new Markdown file at the root and opens it for renaming. */
  export async function createFile() {
    const created = await invoke<FolderEntry>("create_file", {
      parentDir: rootPath,
      name: "Untitled",
    });
    refreshToken += 1;
    pendingRenamePath = created.path;
  }

  /** Creates a new folder at the root and opens it for renaming. */
  export async function createFolder() {
    const created = await invoke<FolderEntry>("create_folder", {
      parentDir: rootPath,
      name: "New Folder",
    });
    refreshToken += 1;
    pendingRenamePath = created.path;
  }

  // Dropping onto the tree's empty background moves an item back up
  // to the root. Rows that accept the drop themselves (folder rows)
  // stop this from firing via stopPropagation.
  function handleRootDragOver(event: DragEvent) {
    event.preventDefault();
  }

  async function handleRootDrop(event: DragEvent) {
    event.preventDefault();
    const fromPath = event.dataTransfer?.getData("text/plain");
    if (!fromPath) return;

    const name =
      event.dataTransfer?.getData("application/x-markive-name") || fromPath.split(/[\\/]/).pop() || fromPath;
    const to = destinationPath(rootPath, name);
    if (to === fromPath) return;

    try {
      const updated = await invoke<FolderEntry>("move_entry", { from: fromPath, to });
      onEntryMoved(fromPath, updated);
      refreshToken += 1;
    } catch (moveError) {
      onError(moveError instanceof Error ? moveError.message : String(moveError));
    }
  }
</script>

<div
  class="min-h-0 overflow-auto p-1.5"
  role="tree"
  tabindex="-1"
  aria-label="Folder contents"
  ondragover={handleRootDragOver}
  ondrop={handleRootDrop}
>
  {#if error}
    <p class="flex items-center gap-1.5 px-1.5 py-1 text-xs text-destructive">
      <FileWarning aria-hidden="true" class="size-3 shrink-0" />
      <span class="truncate">{error}</span>
    </p>
  {:else if entries && entries.length === 0}
    <p class="px-1.5 py-1 text-xs text-muted-foreground">Empty folder.</p>
  {:else}
    {#each visible as entry (entry.path)}
      <ExplorerNode
        {entry}
        depth={0}
        ancestorPaths={[rootPath]}
        {showHidden}
        {activePath}
        {isActiveDirty}
        {refreshToken}
        {pendingRenamePath}
        {actions}
      />
    {/each}
  {/if}
</div>
