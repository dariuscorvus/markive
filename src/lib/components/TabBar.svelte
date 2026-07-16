<script lang="ts">
  import { X } from "@lucide/svelte";

  import { isTabDirty, tabTitle, type Tab } from "$lib/tab-state";

  let {
    tabs,
    activeTabId,
    onSelect,
    onClose,
    onReorder,
  }: {
    tabs: Tab[];
    activeTabId: string | null;
    onSelect: (id: string) => void;
    onClose: (id: string) => void;
    onReorder: (fromIndex: number, toIndex: number) => void;
  } = $props();

  let dragIndex = $state<number | null>(null);

  function handleDrop(index: number) {
    if (dragIndex !== null && dragIndex !== index) onReorder(dragIndex, index);
    dragIndex = null;
  }
</script>

<div
  class="flex items-stretch overflow-x-auto border-b border-border bg-secondary/40"
  role="tablist"
  aria-label="Open documents"
>
  {#each tabs as tab, index (tab.id)}
    <div
      role="presentation"
      draggable="true"
      ondragstart={() => (dragIndex = index)}
      ondragover={(event) => event.preventDefault()}
      ondrop={() => handleDrop(index)}
      class={`group flex shrink-0 items-center gap-1.5 border-r border-border py-1.5 pl-3 pr-1.5 text-sm ${
        tab.id === activeTabId
          ? "bg-card text-foreground"
          : "text-muted-foreground hover:bg-secondary"
      }`}
    >
      <button
        type="button"
        role="tab"
        aria-selected={tab.id === activeTabId}
        class="max-w-40 truncate text-left"
        onclick={() => onSelect(tab.id)}
        title={tab.source.kind === "file" ? tab.source.path : tabTitle(tab)}
      >
        {tabTitle(tab)}
      </button>
      {#if isTabDirty(tab)}
        <span
          class="shrink-0 text-foreground"
          title="Unsaved changes"
          aria-label="Unsaved changes">•</span
        >
      {/if}
      <button
        type="button"
        class="shrink-0 rounded p-0.5 opacity-0 hover:bg-border group-hover:opacity-100"
        aria-label={`Close ${tabTitle(tab)}`}
        onclick={(event) => {
          event.stopPropagation();
          onClose(tab.id);
        }}
      >
        <X aria-hidden="true" class="size-3" />
      </button>
    </div>
  {/each}
</div>
