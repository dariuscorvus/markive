<script lang="ts">
  import { ChevronRight, File, Folder, Star } from "@lucide/svelte";

  import type { FavoritesActions, FavoritesTreeNode } from "$lib/favorites-state";
  import FavoritesTree from "./FavoritesTree.svelte";

  let {
    node,
    depth,
    expandedPaths,
    revealPath,
    revealToken,
    actions,
  }: {
    node: FavoritesTreeNode;
    depth: number;
    expandedPaths: Set<string>;
    revealPath: string | null;
    revealToken: number;
    actions: FavoritesActions;
  } = $props();

  let rowEl = $state<HTMLButtonElement | null>(null);
  let highlighted = $state(false);

  let expanded = $derived(expandedPaths.has(node.path));

  function toggle() {
    if (node.kind !== "directory") return;
    if (expandedPaths.has(node.path)) {
      expandedPaths.delete(node.path);
    } else {
      expandedPaths.add(node.path);
    }
  }

  function activate() {
    if (node.kind === "directory") {
      toggle();
    } else {
      actions.onOpenFile(node.path);
    }
  }

  // Scrolls this row into view and briefly highlights it when it
  // becomes the reveal target. `revealToken` is bumped on every reveal
  // request, even to the same path, so clicking the same favorited
  // directory twice still re-scrolls and re-highlights.
  $effect(() => {
    void revealToken;
    if (node.path !== revealPath || !rowEl) return;
    rowEl.scrollIntoView({ block: "nearest" });
    highlighted = true;
    const timer = setTimeout(() => {
      highlighted = false;
    }, 1200);
    return () => clearTimeout(timer);
  });
</script>

<div>
  <div class="group relative">
    <button
      bind:this={rowEl}
      type="button"
      class={`flex w-full items-center gap-1.5 rounded px-1.5 py-1 text-left text-sm hover:bg-secondary ${highlighted ? "bg-secondary" : ""} text-muted-foreground`}
      style={`padding-left: ${0.375 + depth * 1}rem`}
      onclick={activate}
      title={node.path}
    >
      {#if node.kind === "directory"}
        <ChevronRight
          aria-hidden="true"
          class={`size-3.5 shrink-0 transition-transform ${expanded ? "rotate-90" : ""}`}
        />
        <Folder aria-hidden="true" class="size-3.5 shrink-0" />
      {:else}
        <span class="w-3.5 shrink-0"></span>
        <File aria-hidden="true" class="size-3.5 shrink-0" />
      {/if}
      <span class="min-w-0 flex-1 truncate">{node.name}</span>
    </button>
    {#if node.isFavorited}
      <button
        type="button"
        class="absolute right-1.5 top-1/2 -translate-y-1/2 rounded p-0.5 opacity-0 hover:bg-border group-hover:opacity-100"
        aria-label={`Remove ${node.name} from favorites`}
        onclick={(event) => {
          event.stopPropagation();
          actions.onRemove(node.path);
        }}
      >
        <Star aria-hidden="true" class="size-3 shrink-0 fill-current" />
      </button>
    {/if}
  </div>

  {#if expanded}
    {#each node.children as child (child.path)}
      <FavoritesTree node={child} depth={depth + 1} {expandedPaths} {revealPath} {revealToken} {actions} />
    {/each}
  {/if}
</div>
