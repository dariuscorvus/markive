<script lang="ts">
  import { File, Folder, Star } from "@lucide/svelte";

  import { fileName } from "$lib/document-state";
  import type { FavoriteEntry, FavoritesActions } from "$lib/favorites-state";

  let {
    entries,
    emptyMessage,
    actions,
  }: {
    entries: FavoriteEntry[];
    emptyMessage: string;
    actions: FavoritesActions;
  } = $props();

  function activate(entry: FavoriteEntry) {
    if (entry.kind === "directory") {
      actions.onRevealDirectory(entry.path);
    } else {
      actions.onOpenFile(entry.path);
    }
  }
</script>

<div class="min-h-0 overflow-auto p-1.5">
  {#if entries.length === 0}
    <p class="px-1.5 py-1 text-xs text-muted-foreground">{emptyMessage}</p>
  {:else}
    {#each entries as entry (entry.path)}
      <div class="flex items-center gap-1.5 rounded px-1.5 py-1 text-sm hover:bg-secondary">
        <button
          type="button"
          class="flex min-w-0 flex-1 items-center gap-1.5 text-left text-muted-foreground"
          onclick={() => activate(entry)}
          title={entry.path}
        >
          {#if entry.kind === "directory"}
            <Folder aria-hidden="true" class="size-3.5 shrink-0" />
          {:else}
            <File aria-hidden="true" class="size-3.5 shrink-0" />
          {/if}
          <span class="min-w-0 flex-1 truncate">{fileName(entry.path)}</span>
        </button>
        <button
          type="button"
          class="shrink-0 rounded p-0.5 hover:bg-border"
          aria-label={`Remove ${fileName(entry.path)} from favorites`}
          onclick={() => actions.onRemove(entry.path)}
        >
          <Star aria-hidden="true" class="size-3.5 shrink-0 fill-current" />
        </button>
      </div>
    {/each}
  {/if}
</div>
