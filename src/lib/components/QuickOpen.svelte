<script lang="ts">
  import { File, Loader2, Search } from "@lucide/svelte";
  import { invoke } from "@tauri-apps/api/core";

  import { isMarkdownPath } from "$lib/document-state";
  import { searchQuickOpenEntries, type QuickOpenEntry } from "$lib/quick-open";

  let {
    rootPath,
    includeHidden,
    onOpenFile,
    onClose,
  }: {
    rootPath: string;
    includeHidden: boolean;
    onOpenFile: (path: string) => void;
    onClose: () => void;
  } = $props();

  let query = $state("");
  let entries = $state<QuickOpenEntry[] | null>(null);
  let truncated = $state(false);
  let error = $state<string | null>(null);
  let selectedIndex = $state(0);
  let inputEl = $state<HTMLInputElement | null>(null);
  let listEl = $state<HTMLElement | null>(null);

  // Re-walks the root every time the palette opens — the tree may
  // have changed (create/rename/move/delete) since it was last open,
  // and a fresh walk keeps that simple instead of threading cache
  // invalidation through every file operation.
  $effect(() => {
    void loadEntries(rootPath, includeHidden);
  });

  async function loadEntries(path: string, hidden: boolean) {
    entries = null;
    error = null;
    try {
      const result = await invoke<{ entries: QuickOpenEntry[]; truncated: boolean }>(
        "list_all_files",
        { root: path, includeHidden: hidden },
      );
      entries = result.entries;
      truncated = result.truncated;
    } catch (loadError) {
      error = loadError instanceof Error ? loadError.message : String(loadError);
    }
  }

  // Results appear incrementally as the query changes — filtering an
  // already-fetched list is instant, so there's no debounce here.
  let results = $derived(entries ? searchQuickOpenEntries(entries, query) : []);

  $effect(() => {
    void results;
    selectedIndex = 0;
  });

  $effect(() => {
    inputEl?.focus();
  });

  function scrollSelectedIntoView() {
    listEl?.querySelector(`[data-index="${selectedIndex}"]`)?.scrollIntoView({ block: "nearest" });
  }

  function moveSelection(delta: 1 | -1) {
    if (results.length === 0) return;
    selectedIndex = (selectedIndex + delta + results.length) % results.length;
    queueMicrotask(scrollSelectedIntoView);
  }

  function openSelected() {
    const entry = results[selectedIndex];
    if (!entry) return;
    onOpenFile(entry.path);
  }

  function handleKeydown(event: KeyboardEvent) {
    if (event.key === "Escape") {
      event.preventDefault();
      onClose();
    } else if (event.key === "ArrowDown") {
      event.preventDefault();
      moveSelection(1);
    } else if (event.key === "ArrowUp") {
      event.preventDefault();
      moveSelection(-1);
    } else if (event.key === "Enter") {
      event.preventDefault();
      openSelected();
    }
  }
</script>

<div class="fixed inset-0 z-50 grid place-items-start justify-center pt-32" role="presentation">
  <button
    type="button"
    class="fixed inset-0 cursor-default bg-black/40"
    aria-label="Close Quick Open"
    onclick={onClose}
  ></button>
  <div
    class="relative flex w-full max-w-lg flex-col overflow-hidden rounded-lg border border-border bg-background shadow-lg"
    role="dialog"
    aria-modal="true"
    aria-label="Quick Open"
  >
    <div class="flex items-center gap-2 border-b border-border px-3 py-2">
      <Search aria-hidden="true" class="size-3.5 shrink-0 text-muted-foreground" />
      <input
        bind:this={inputEl}
        bind:value={query}
        onkeydown={handleKeydown}
        type="text"
        placeholder="Quick Open…"
        aria-label="Quick Open"
        autocomplete="off"
        autocorrect="off"
        autocapitalize="off"
        spellcheck="false"
        class="min-w-0 flex-1 bg-transparent text-sm outline-none placeholder:text-muted-foreground"
      />
      {#if entries === null && !error}
        <Loader2 aria-hidden="true" class="size-3.5 shrink-0 animate-spin text-muted-foreground" />
      {/if}
    </div>

    {#if error}
      <p class="px-3 py-3 text-sm text-destructive">{error}</p>
    {:else if entries !== null}
      <div bind:this={listEl} class="max-h-80 overflow-y-auto p-1.5" role="listbox" aria-label="Results">
        {#if results.length === 0}
          <p class="px-1.5 py-2 text-sm text-muted-foreground">No matching files.</p>
        {:else}
          {#each results as entry, index (entry.path)}
            <button
              type="button"
              data-index={index}
              role="option"
              aria-selected={index === selectedIndex}
              class={`flex w-full items-center gap-2 rounded px-1.5 py-1.5 text-left text-sm ${index === selectedIndex ? "bg-secondary text-foreground" : "text-muted-foreground hover:bg-secondary"}`}
              onmouseenter={() => (selectedIndex = index)}
              onclick={openSelected}
            >
              <File aria-hidden="true" class="size-3.5 shrink-0" />
              <span class="min-w-0 flex-1 truncate">{entry.name}</span>
              <span class="shrink-0 truncate text-xs text-muted-foreground/70">{entry.relativePath}</span>
              {#if !isMarkdownPath(entry.path)}
                <span
                  class="shrink-0 rounded border border-border px-1 text-[10px] uppercase text-muted-foreground"
                >
                  file
                </span>
              {/if}
            </button>
          {/each}
        {/if}
      </div>
      {#if truncated}
        <p class="border-t border-border px-3 py-1.5 text-xs text-muted-foreground">
          Showing a partial list — this folder has more files than Quick Open indexes at once.
        </p>
      {/if}
    {/if}
  </div>
</div>
