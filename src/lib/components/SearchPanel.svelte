<script lang="ts">
  import { CaseSensitive, Loader2, Regex, Search, WholeWord, X } from "@lucide/svelte";
  import { invoke } from "@tauri-apps/api/core";
  import { listen } from "@tauri-apps/api/event";
  import { onMount } from "svelte";

  import { Button } from "$lib/components/ui/button";
  import {
    appendSearchResult,
    highlightMatch,
    totalMatchCount,
    type SearchFileResult,
  } from "$lib/search-state";

  let {
    rootPath,
    includeHidden,
    onOpenMatch,
    onClose,
  }: {
    rootPath: string;
    includeHidden: boolean;
    onOpenMatch: (path: string, line: number, matchStart: number, matchEnd: number) => void;
    onClose: () => void;
  } = $props();

  let query = $state("");
  let caseSensitive = $state(false);
  let wholeWord = $state(false);
  let isRegex = $state(false);
  let results = $state<SearchFileResult[]>([]);
  let searching = $state(false);
  let truncated = $state(false);
  let error = $state<string | null>(null);
  let inputEl = $state<HTMLInputElement | null>(null);

  let currentSearchId = "";
  let searchTimer: ReturnType<typeof setTimeout> | undefined;

  let matchCount = $derived(totalMatchCount(results));

  onMount(() => {
    const unlistenResult = listen<SearchFileResult>("search-result", (event) => {
      if (event.payload.searchId !== currentSearchId) return;
      results = appendSearchResult(results, event.payload);
    });
    const unlistenComplete = listen<{ searchId: string; filesSearched: number; truncated: boolean }>(
      "search-complete",
      (event) => {
        if (event.payload.searchId !== currentSearchId) return;
        searching = false;
        truncated = event.payload.truncated;
      },
    );

    return () => {
      void unlistenResult.then((stop) => stop());
      void unlistenComplete.then((stop) => stop());
      void invoke("stop_search").catch(() => {
        // Nothing to clean up if this fails — the search just runs to
        // completion in the background.
      });
    };
  });

  async function runSearch() {
    results = [];
    error = null;
    truncated = false;

    const trimmed = query.trim();
    if (!trimmed) {
      searching = false;
      return;
    }

    const searchId = crypto.randomUUID();
    currentSearchId = searchId;
    searching = true;

    try {
      await invoke("search_markdown", {
        searchId,
        root: rootPath,
        query: trimmed,
        options: { caseSensitive, wholeWord, isRegex, includeHidden },
      });
    } catch (invokeError) {
      if (searchId !== currentSearchId) return;
      error = invokeError instanceof Error ? invokeError.message : String(invokeError);
      searching = false;
    }
  }

  // Debounced so a burst of keystrokes (or toggling a mode) starts
  // one search, not one per change — each new search's searchId
  // implicitly discards results from whatever came before.
  $effect(() => {
    void [query, caseSensitive, wholeWord, isRegex];
    clearTimeout(searchTimer);
    searchTimer = setTimeout(() => void runSearch(), 200);
  });

  $effect(() => {
    inputEl?.focus();
  });

  function handleKeydown(event: KeyboardEvent) {
    if (event.key === "Escape") {
      event.preventDefault();
      onClose();
    }
  }

  function openMatch(path: string, line: number, matchStart: number, matchEnd: number) {
    onOpenMatch(path, line, matchStart, matchEnd);
  }
</script>

<div class="fixed inset-0 z-50 grid place-items-start justify-center pt-20" role="presentation">
  <button
    type="button"
    class="fixed inset-0 cursor-default bg-black/40"
    aria-label="Close search"
    onclick={onClose}
  ></button>
  <div
    class="relative flex h-[70vh] w-full max-w-2xl flex-col overflow-hidden rounded-lg border border-border bg-background shadow-lg"
    role="dialog"
    aria-modal="true"
    aria-label="Find in Folder"
  >
    <div class="flex items-center gap-2 border-b border-border px-3 py-2">
      <Search aria-hidden="true" class="size-3.5 shrink-0 text-muted-foreground" />
      <input
        bind:this={inputEl}
        bind:value={query}
        onkeydown={handleKeydown}
        type="text"
        placeholder="Find in Folder…"
        aria-label="Find in Folder"
        autocomplete="off"
        autocorrect="off"
        autocapitalize="off"
        spellcheck="false"
        class="min-w-0 flex-1 bg-transparent text-sm outline-none placeholder:text-muted-foreground"
      />
      <div class="flex shrink-0 items-center gap-0.5">
        <Button
          variant={caseSensitive ? "secondary" : "ghost"}
          size="icon-sm"
          aria-label="Match case"
          aria-pressed={caseSensitive}
          onclick={() => (caseSensitive = !caseSensitive)}
        >
          <CaseSensitive aria-hidden="true" class="size-3.5" />
        </Button>
        <Button
          variant={wholeWord ? "secondary" : "ghost"}
          size="icon-sm"
          aria-label="Match whole word"
          aria-pressed={wholeWord}
          onclick={() => (wholeWord = !wholeWord)}
        >
          <WholeWord aria-hidden="true" class="size-3.5" />
        </Button>
        <Button
          variant={isRegex ? "secondary" : "ghost"}
          size="icon-sm"
          aria-label="Use regular expression"
          aria-pressed={isRegex}
          onclick={() => (isRegex = !isRegex)}
        >
          <Regex aria-hidden="true" class="size-3.5" />
        </Button>
      </div>
      {#if searching}
        <Loader2 aria-hidden="true" class="size-3.5 shrink-0 animate-spin text-muted-foreground" />
      {/if}
      <Button variant="ghost" size="icon-sm" aria-label="Close search" onclick={onClose}>
        <X aria-hidden="true" class="size-3.5" />
      </Button>
    </div>

    <div class="min-h-0 flex-1 overflow-y-auto p-1.5">
      {#if error}
        <p class="px-1.5 py-2 text-sm text-destructive">{error}</p>
      {:else if !query.trim()}
        <p class="px-1.5 py-2 text-sm text-muted-foreground">Type to search Markdown files.</p>
      {:else if results.length === 0 && !searching}
        <p class="px-1.5 py-2 text-sm text-muted-foreground">No matches.</p>
      {:else}
        {#each results as result (result.path)}
          <div class="mb-2">
            <p class="truncate px-1.5 py-1 text-xs font-medium text-muted-foreground">
              {result.relativePath}
              <span class="text-muted-foreground/70">({result.matches.length})</span>
            </p>
            {#each result.matches as match, index (index)}
              <button
                type="button"
                class="flex w-full items-baseline gap-2 rounded px-1.5 py-1 text-left text-sm hover:bg-secondary"
                onclick={() => openMatch(result.path, match.line, match.matchStart, match.matchEnd)}
              >
                <span class="shrink-0 font-mono text-xs text-muted-foreground">{match.line}</span>
                <span class="min-w-0 flex-1 truncate font-mono text-xs">
                  {#each highlightMatch(match.lineText, match.matchStart, match.matchEnd) as segment, segmentIndex (segmentIndex)}
                    {#if segment.matched}
                      <mark class="rounded bg-yellow-400/40 text-foreground">{segment.text}</mark>
                    {:else}
                      {segment.text}
                    {/if}
                  {/each}
                </span>
              </button>
            {/each}
          </div>
        {/each}
      {/if}
    </div>

    {#if matchCount > 0 || truncated}
      <div class="border-t border-border px-3 py-1.5 text-xs text-muted-foreground">
        {matchCount} {matchCount === 1 ? "match" : "matches"} in {results.length}
        {results.length === 1 ? "file" : "files"}
        {#if truncated}
          — showing a partial list, this search matched more than it stopped at
        {/if}
      </div>
    {/if}
  </div>
</div>
