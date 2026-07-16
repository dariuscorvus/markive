<script lang="ts">
  import { ChevronRight, File, FileWarning, Folder, Link, Loader2 } from "@lucide/svelte";
  import { invoke } from "@tauri-apps/api/core";

  import { isSymlinkCycle, visibleEntries, type FolderEntry } from "$lib/folder-state";
  import ExplorerNode from "./ExplorerNode.svelte";

  let {
    entry,
    depth,
    ancestorPaths,
    showHidden,
    activePath,
    isActiveDirty,
    onOpenFile,
  }: {
    entry: FolderEntry;
    depth: number;
    ancestorPaths: readonly string[];
    showHidden: boolean;
    activePath: string | null;
    isActiveDirty: boolean;
    onOpenFile: (path: string) => void;
  } = $props();

  let expanded = $state(false);
  let children = $state<FolderEntry[] | null>(null);
  let loading = $state(false);
  let loadError = $state<string | null>(null);

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
      onOpenFile(entry.path);
    }
  }
</script>

<div>
  <button
    type="button"
    class={`flex w-full items-center gap-1.5 rounded px-1.5 py-1 text-left text-sm hover:bg-secondary ${isActive ? "bg-secondary text-foreground" : "text-muted-foreground"} ${isCycle ? "cursor-not-allowed opacity-50" : ""}`}
    style={`padding-left: ${0.375 + depth * 1}rem`}
    onclick={activate}
    disabled={isCycle}
    title={isCycle ? `${entry.name} — symlink loop, not expanded` : entry.path}
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
          {onOpenFile}
        />
      {/each}
    {/if}
  {/if}
</div>
