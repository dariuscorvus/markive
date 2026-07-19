<script lang="ts">
  import { X } from "@lucide/svelte";
  import { SvelteSet } from "svelte/reactivity";

  import {
    ancestorChain,
    buildFavoritesTree,
    sortedAll,
    sortedRecent,
    type FavoriteEntry,
    type FavoritesActions,
  } from "$lib/favorites-state";
  import FavoritesList from "./FavoritesList.svelte";
  import FavoritesTree from "./FavoritesTree.svelte";

  let {
    favorites,
    onOpenFile,
    onRemove,
    onClose,
  }: {
    favorites: FavoriteEntry[];
    onOpenFile: (path: string) => void;
    onRemove: (path: string) => void;
    onClose: () => void;
  } = $props();

  let activeTab = $state<"all" | "recent" | "explorer">("all");
  let expandedPaths = new SvelteSet<string>();
  let revealPath = $state<string | null>(null);
  let revealToken = $state(0);

  // Switches to the Explorer tab and expands every ancestor down to
  // `path` so a favorited directory clicked from All or Recent (or
  // from within the tree itself) is visible and highlighted there.
  // `revealToken` is bumped even when `revealPath` doesn't change, so
  // revealing the same directory twice still re-scrolls.
  function onRevealDirectory(path: string) {
    activeTab = "explorer";
    for (const ancestor of ancestorChain(path)) expandedPaths.add(ancestor);
    expandedPaths.add(path);
    revealPath = path;
    revealToken += 1;
  }

  let actions: FavoritesActions = $derived({
    onOpenFile,
    onRevealDirectory,
    onRemove,
  });

  let allEntries = $derived(sortedAll(favorites));
  let recentEntries = $derived(sortedRecent(favorites));
  let tree = $derived(buildFavoritesTree(favorites));
</script>

<aside class="flex w-64 shrink-0 flex-col border-r border-border">
  <div class="flex items-center justify-between gap-2 border-b border-border px-2 py-2">
    <div class="flex items-center gap-1 text-sm font-medium" role="tablist" aria-label="Favorites views">
      <button
        type="button"
        role="tab"
        aria-selected={activeTab === "all"}
        class={`rounded px-1.5 py-1 ${activeTab === "all" ? "bg-secondary text-foreground" : "text-muted-foreground hover:bg-secondary"}`}
        onclick={() => (activeTab = "all")}
      >
        All
      </button>
      <button
        type="button"
        role="tab"
        aria-selected={activeTab === "recent"}
        class={`rounded px-1.5 py-1 ${activeTab === "recent" ? "bg-secondary text-foreground" : "text-muted-foreground hover:bg-secondary"}`}
        onclick={() => (activeTab = "recent")}
      >
        Recent
      </button>
      <button
        type="button"
        role="tab"
        aria-selected={activeTab === "explorer"}
        class={`rounded px-1.5 py-1 ${activeTab === "explorer" ? "bg-secondary text-foreground" : "text-muted-foreground hover:bg-secondary"}`}
        onclick={() => (activeTab = "explorer")}
      >
        Explorer
      </button>
    </div>
    <button
      type="button"
      class="shrink-0 rounded p-1 text-muted-foreground hover:bg-secondary"
      aria-label="Hide favorites"
      onclick={onClose}
    >
      <X aria-hidden="true" class="size-3.5" />
    </button>
  </div>

  {#if activeTab === "all"}
    <FavoritesList entries={allEntries} emptyMessage="No favorites yet." {actions} />
  {:else if activeTab === "recent"}
    <FavoritesList entries={recentEntries} emptyMessage="Nothing added recently." {actions} />
  {:else}
    <div class="min-h-0 overflow-auto p-1.5" role="tree" tabindex="-1" aria-label="Favorites tree">
      {#if tree.length === 0}
        <p class="px-1.5 py-1 text-xs text-muted-foreground">No favorites yet.</p>
      {:else}
        {#each tree as node (node.path)}
          <FavoritesTree {node} depth={0} {expandedPaths} {revealPath} {revealToken} {actions} />
        {/each}
      {/if}
    </div>
  {/if}
</aside>
