<script lang="ts">
  import { ChevronRight, File, FilePlus, FileWarning, Folder, FolderPlus, Link, Loader2, Trash2 } from "@lucide/svelte";
  import { invoke } from "@tauri-apps/api/core";

  import {
    destinationPath,
    isSameOrDescendant,
    isSymlinkCycle,
    visibleEntries,
    type ExplorerActions,
    type FolderEntry,
  } from "$lib/folder-state";
  import ExplorerNode from "./ExplorerNode.svelte";

  let {
    entry,
    depth,
    ancestorPaths,
    showHidden,
    activePath,
    isActiveDirty,
    refreshToken,
    pendingRenamePath,
    actions,
  }: {
    entry: FolderEntry;
    depth: number;
    ancestorPaths: readonly string[];
    showHidden: boolean;
    activePath: string | null;
    isActiveDirty: boolean;
    refreshToken: number;
    pendingRenamePath: string | null;
    actions: ExplorerActions;
  } = $props();

  let expanded = $state(false);
  let children = $state<FolderEntry[] | null>(null);
  let loading = $state(false);
  let loadError = $state<string | null>(null);
  let menuOpen = $state(false);
  let menuPos = $state({ x: 0, y: 0 });
  let renaming = $state(false);
  let renameValue = $state("");
  let renameInput = $state<HTMLInputElement | null>(null);

  // A symlink whose canonical target is already an ancestor of this
  // node would expand into itself forever; refuse before ever
  // fetching its children.
  let isCycle = $derived(entry.isDir && isSymlinkCycle(entry.path, ancestorPaths));
  let isActive = $derived(entry.path === activePath);
  let visibleChildren = $derived(children ? visibleEntries(children, showHidden) : []);

  async function loadChildren() {
    loading = true;
    loadError = null;
    try {
      children = await invoke<FolderEntry[]>("read_folder_entries", { path: entry.path });
    } catch (error) {
      loadError = error instanceof Error ? error.message : String(error);
    } finally {
      loading = false;
    }
  }

  function toggle() {
    if (!entry.isDir || isCycle) return;

    expanded = !expanded;
    if (expanded && children === null && !loading) void loadChildren();
  }

  function activate() {
    if (entry.isDir) {
      toggle();
    } else {
      actions.onOpenFile(entry.path);
    }
  }

  // Every loaded folder re-fetches when something changes anywhere in
  // the tree — the simplest way for a rename or move to be reflected
  // both at its old location and its new one, wherever in the tree
  // those are.
  $effect(() => {
    void refreshToken;
    if (children !== null) {
      children = null;
      if (expanded) void loadChildren();
    }
  });

  // A "New File"/"New Folder" action elsewhere in the tree asks the
  // freshly created entry to open in rename mode as soon as it
  // appears here.
  $effect(() => {
    if (pendingRenamePath === entry.path) {
      startRename();
      actions.onRenameConsumed();
    }
  });

  function openMenu(event: MouseEvent) {
    event.preventDefault();
    menuPos = { x: event.clientX, y: event.clientY };
    menuOpen = true;
  }

  function startRename() {
    renameValue = entry.name;
    renaming = true;
    menuOpen = false;
    queueMicrotask(() => {
      renameInput?.focus();
      renameInput?.select();
    });
  }

  function parentDirOf(path: string): string {
    return path.slice(0, path.lastIndexOf("/"));
  }

  async function commitRename() {
    // Escape already set renaming false and is not asking to commit;
    // the blur that follows removing the input from the DOM must not
    // re-trigger a rename.
    if (!renaming) return;

    const name = renameValue.trim();
    renaming = false;
    if (!name || name === entry.name) return;

    const to = destinationPath(parentDirOf(entry.path), name);
    try {
      const updated = await invoke<FolderEntry>("move_entry", { from: entry.path, to });
      actions.onEntryMoved(entry.path, updated);
      actions.onRefreshNeeded();
    } catch (error) {
      actions.onError(error instanceof Error ? error.message : String(error));
    }
  }

  function handleRenameKeydown(event: KeyboardEvent) {
    if (event.key === "Enter") {
      event.preventDefault();
      // Deferred a frame: blurring (and the DOM swap back to a plain
      // row that follows) synchronously inside a key event dispatched
      // through the accessibility layer — as VoiceOver and assistive
      // automation both do — can race WebKit's own AX focus handling
      // for the input being removed. Committing on the next frame
      // keeps the DOM mutation out of that call stack.
      const input = event.target as HTMLInputElement;
      requestAnimationFrame(() => input.blur());
    } else if (event.key === "Escape") {
      event.preventDefault();
      renaming = false;
    }
  }

  async function createHere(kind: "file" | "folder") {
    menuOpen = false;
    try {
      const created = await invoke<FolderEntry>(kind === "file" ? "create_file" : "create_folder", {
        parentDir: entry.path,
        name: kind === "file" ? "Untitled" : "New Folder",
      });
      expanded = true;
      await loadChildren();
      actions.onRequestRename(created.path);
    } catch (error) {
      actions.onError(error instanceof Error ? error.message : String(error));
    }
  }

  async function handleDelete() {
    menuOpen = false;
    try {
      await invoke("delete_entry", { path: entry.path });
      actions.onEntryDeleted(entry.path);
      actions.onRefreshNeeded();
    } catch (error) {
      actions.onError(error instanceof Error ? error.message : String(error));
    }
  }

  function handleDragStart(event: DragEvent) {
    event.dataTransfer?.setData("text/plain", entry.path);
    event.dataTransfer?.setData("application/x-markive-name", entry.name);
  }

  let dragOver = $state(false);

  function handleDragOver(event: DragEvent) {
    if (!entry.isDir || isCycle) return;
    event.preventDefault();
    dragOver = true;
  }

  async function handleDrop(event: DragEvent) {
    event.preventDefault();
    event.stopPropagation();
    dragOver = false;
    if (!entry.isDir) return;

    const fromPath = event.dataTransfer?.getData("text/plain");
    if (!fromPath || isSameOrDescendant(entry.path, fromPath)) return;

    const name =
      event.dataTransfer?.getData("application/x-markive-name") || fromPath.split(/[\\/]/).pop() || fromPath;
    const to = destinationPath(entry.path, name);
    if (to === fromPath) return;

    try {
      const updated = await invoke<FolderEntry>("move_entry", { from: fromPath, to });
      actions.onEntryMoved(fromPath, updated);
      actions.onRefreshNeeded();
    } catch (error) {
      actions.onError(error instanceof Error ? error.message : String(error));
    }
  }
</script>

<div>
  {#if renaming}
    <div class="flex items-center gap-1.5 px-1.5 py-1" style={`padding-left: ${0.375 + depth * 1}rem`}>
      <span class="w-3.5 shrink-0"></span>
      {#if entry.isDir}
        <Folder aria-hidden="true" class="size-3.5 shrink-0" />
      {:else}
        <File aria-hidden="true" class="size-3.5 shrink-0" />
      {/if}
      <input
        bind:this={renameInput}
        bind:value={renameValue}
        onkeydown={handleRenameKeydown}
        onblur={commitRename}
        type="text"
        aria-label={`Rename ${entry.name}`}
        autocomplete="off"
        autocorrect="off"
        autocapitalize="off"
        spellcheck="false"
        class="min-w-0 flex-1 rounded border border-ring bg-background px-1 py-0.5 text-sm outline-none"
      />
    </div>
  {:else}
    <button
      type="button"
      class={`flex w-full items-center gap-1.5 rounded px-1.5 py-1 text-left text-sm hover:bg-secondary ${isActive ? "bg-secondary text-foreground" : "text-muted-foreground"} ${isCycle ? "cursor-not-allowed opacity-50" : ""} ${dragOver ? "ring-1 ring-inset ring-ring" : ""}`}
      style={`padding-left: ${0.375 + depth * 1}rem`}
      onclick={activate}
      oncontextmenu={openMenu}
      disabled={isCycle}
      title={isCycle ? `${entry.name} — symlink loop, not expanded` : entry.path}
      draggable="true"
      ondragstart={handleDragStart}
      ondragover={handleDragOver}
      ondragleave={() => (dragOver = false)}
      ondrop={handleDrop}
    >
      {#if entry.isDir}
        <ChevronRight
          aria-hidden="true"
          class={`size-3.5 shrink-0 transition-transform ${expanded ? "rotate-90" : ""}`}
        />
        <Folder aria-hidden="true" class="size-3.5 shrink-0" />
      {:else}
        <span class="w-3.5 shrink-0"></span>
        <File aria-hidden="true" class="size-3.5 shrink-0" />
      {/if}
      <span class="min-w-0 flex-1 truncate">{entry.name}</span>
      {#if entry.isSymlink}
        <Link aria-hidden="true" class="size-3 shrink-0 text-muted-foreground" />
      {/if}
      {#if isActive && isActiveDirty}
        <span class="shrink-0 text-foreground" title="Unsaved changes" aria-label="Unsaved changes"
          >•</span
        >
      {/if}
      {#if loading}
        <Loader2 aria-hidden="true" class="size-3 shrink-0 animate-spin" />
      {/if}
    </button>
  {/if}

  {#if menuOpen}
    <button
      type="button"
      class="fixed inset-0 z-40 cursor-default"
      aria-label="Close menu"
      onclick={() => (menuOpen = false)}
    ></button>
    <div
      class="fixed z-50 min-w-40 rounded-md border border-border bg-background py-1 text-sm shadow-lg"
      style={`left: ${menuPos.x}px; top: ${menuPos.y}px`}
      role="menu"
    >
      {#if entry.isDir}
        <button
          type="button"
          role="menuitem"
          class="flex w-full items-center gap-2 px-3 py-1.5 text-left hover:bg-secondary"
          onclick={() => void createHere("file")}
        >
          <FilePlus aria-hidden="true" class="size-3.5" />
          New File
        </button>
        <button
          type="button"
          role="menuitem"
          class="flex w-full items-center gap-2 px-3 py-1.5 text-left hover:bg-secondary"
          onclick={() => void createHere("folder")}
        >
          <FolderPlus aria-hidden="true" class="size-3.5" />
          New Folder
        </button>
        <div class="my-1 border-t border-border"></div>
      {/if}
      <button
        type="button"
        role="menuitem"
        class="flex w-full items-center gap-2 px-3 py-1.5 text-left hover:bg-secondary"
        onclick={startRename}
      >
        Rename
      </button>
      <button
        type="button"
        role="menuitem"
        class="flex w-full items-center gap-2 px-3 py-1.5 text-left text-destructive hover:bg-secondary"
        onclick={() => void handleDelete()}
      >
        <Trash2 aria-hidden="true" class="size-3.5" />
        Move to Trash
      </button>
    </div>
  {/if}

  {#if expanded && !isCycle}
    {#if loadError}
      <p
        class="flex items-center gap-1.5 px-1.5 py-1 text-xs text-destructive"
        style={`padding-left: ${0.375 + (depth + 1) * 1}rem`}
      >
        <FileWarning aria-hidden="true" class="size-3 shrink-0" />
        <span class="truncate">{loadError}</span>
      </p>
    {:else}
      {#each visibleChildren as child (child.path)}
        <ExplorerNode
          entry={child}
          depth={depth + 1}
          ancestorPaths={[...ancestorPaths, entry.path]}
          {showHidden}
          {activePath}
          {isActiveDirty}
          {refreshToken}
          {pendingRenamePath}
          {actions}
        />
      {/each}
    {/if}
  {/if}
</div>
