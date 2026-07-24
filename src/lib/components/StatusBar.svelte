<script lang="ts">
  import { FileText, PanelLeft, Star } from "@lucide/svelte";

  import { Button } from "$lib/components/ui/button";

  let {
    folderRoot,
    showExplorer,
    showFavorites,
    onToggleExplorer,
    onToggleFavorites,
    sourceLabel,
    isDirty,
    cursorInfo,
  }: {
    folderRoot: string | null;
    showExplorer: boolean;
    showFavorites: boolean;
    onToggleExplorer: () => void;
    onToggleFavorites: () => void;
    sourceLabel: string;
    isDirty: boolean;
    cursorInfo: { line: number; column: number; wordCount: number; charCount: number } | null;
  } = $props();
</script>

<div
  class="flex h-7 shrink-0 items-center gap-4 border-t border-border bg-secondary px-2 text-xs text-muted-foreground"
>
  <div class="flex shrink-0 items-center gap-0.5">
    <Button
      variant={showExplorer ? "secondary" : "ghost"}
      size="icon-sm"
      aria-label={showExplorer ? "Hide Explorer" : "Show Explorer"}
      aria-pressed={showExplorer}
      disabled={!folderRoot}
      onclick={onToggleExplorer}
    >
      <PanelLeft aria-hidden="true" class="size-3.5" />
    </Button>
    <Button
      variant={showFavorites ? "secondary" : "ghost"}
      size="icon-sm"
      aria-label={showFavorites ? "Hide Favorites" : "Show Favorites"}
      aria-pressed={showFavorites}
      onclick={onToggleFavorites}
    >
      <Star aria-hidden="true" class="size-3.5" />
    </Button>
  </div>
  <div class="flex min-w-0 flex-1 items-center gap-2 font-mono">
    <FileText aria-hidden="true" class="size-3.5 shrink-0" strokeWidth={1.75} />
    <span class="truncate">{sourceLabel}</span>
    {#if isDirty}
      <span class="shrink-0 text-foreground" title="Unsaved changes" aria-label="Unsaved changes">•</span>
    {/if}
  </div>
  {#if cursorInfo}
    <div class="flex shrink-0 items-center gap-3">
      <span>{cursorInfo.wordCount} words</span>
      <span>{cursorInfo.charCount} chars</span>
      <span>Ln {cursorInfo.line}, Col {cursorInfo.column}</span>
    </div>
  {/if}
</div>
