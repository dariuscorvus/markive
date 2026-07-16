<script lang="ts">
  import { FileWarning } from "@lucide/svelte";
  import { invoke } from "@tauri-apps/api/core";

  import { visibleEntries, type FolderEntry } from "$lib/folder-state";
  import ExplorerNode from "./ExplorerNode.svelte";

  let {
    rootPath,
    showHidden,
    activePath,
    isActiveDirty,
    onOpenFile,
  }: {
    rootPath: string;
    showHidden: boolean;
    activePath: string | null;
    isActiveDirty: boolean;
    onOpenFile: (path: string) => void;
  } = $props();

  let entries = $state<FolderEntry[] | null>(null);
  let error = $state<string | null>(null);

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
  // lazy — so the sidebar isn't empty the moment a folder opens.
  $effect(() => {
    void load(rootPath);
  });

  let visible = $derived(entries ? visibleEntries(entries, showHidden) : []);
</script>

<div class="min-h-0 overflow-auto p-1.5" role="tree" aria-label="Folder contents">
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
        {onOpenFile}
      />
    {/each}
  {/if}
</div>
