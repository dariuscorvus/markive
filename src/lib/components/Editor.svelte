<script lang="ts">
  import { markdown } from "@codemirror/lang-markdown";
  import {
    findNext,
    findPrevious,
    search,
    SearchQuery,
    setSearchQuery,
  } from "@codemirror/search";
  import { Compartment, EditorState } from "@codemirror/state";
  import { EditorView } from "@codemirror/view";
  import { oneDark } from "@codemirror/theme-one-dark";
  import { basicSetup } from "codemirror";
  import { onMount } from "svelte";

  let {
    value,
    dark = false,
    onchange,
  }: {
    value: string;
    dark?: boolean;
    onchange: (value: string) => void;
  } = $props();

  // Swaps the editor theme in place, without resetting editor state.
  const theme = new Compartment();

  let container: HTMLDivElement;
  let view: EditorView | undefined;

  // CodeMirror joins lines with "\n" unless told otherwise; a CRLF
  // document must round-trip byte-identically.
  function stateFor(text: string): EditorState {
    return EditorState.create({
      doc: text,
      extensions: [
        basicSetup,
        // The search state field, driven programmatically from the
        // app's find bar; CodeMirror's own panel stays unbound.
        search(),
        markdown(),
        theme.of(dark ? oneDark : []),
        EditorView.lineWrapping,
        ...(text.includes("\r\n") ? [EditorState.lineSeparator.of("\r\n")] : []),
        EditorView.updateListener.of((update) => {
          if (update.docChanged) {
            onchange(update.state.sliceDoc());
          }
        }),
        EditorView.theme({
          "&": { height: "100%", fontSize: "0.875rem" },
          ".cm-scroller": { fontFamily: "var(--font-mono, monospace)" },
          "&.cm-focused": { outline: "none" },
        }),
      ],
    });
  }

  onMount(() => {
    view = new EditorView({ state: stateFor(value), parent: container });
    view.focus();
    return () => view?.destroy();
  });

  $effect(() => {
    view?.dispatch({ effects: theme.reconfigure(dark ? oneDark : []) });
  });

  // A new document (different text than the editor holds) resets the
  // editor state, including its undo history.
  $effect(() => {
    if (view && value !== view.state.sliceDoc()) {
      view.setState(stateFor(value));
      view.focus();
    }
  });

  /** Sets the active find query and returns the match count. */
  export function setFind(query: string): number {
    if (!view) return 0;

    const searchQuery = new SearchQuery({ search: query, caseSensitive: false });
    view.dispatch({ effects: setSearchQuery.of(searchQuery) });

    if (!query) return 0;
    let count = 0;
    const cursor = searchQuery.getCursor(view.state);
    while (!cursor.next().done) count += 1;
    return count;
  }

  /** Selects and reveals the next match. */
  export function findNextMatch() {
    if (view) findNext(view);
  }

  /** Selects and reveals the previous match. */
  export function findPreviousMatch() {
    if (view) findPrevious(view);
  }
</script>

<div bind:this={container} class="h-full min-h-0 overflow-hidden"></div>
