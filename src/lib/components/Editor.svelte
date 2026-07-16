<script lang="ts">
  import { redo, undo } from "@codemirror/commands";
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
    tabId,
    value,
    dark = false,
    fontSize = 14,
    lineWrap = true,
    onchange,
  }: {
    tabId: string;
    value: string;
    dark?: boolean;
    fontSize?: number;
    lineWrap?: boolean;
    onchange: (value: string) => void;
  } = $props();

  // Compartments swap settings in place, without resetting editor
  // state — preferences apply to the open document immediately.
  const theme = new Compartment();
  const wrapping = new Compartment();
  const sizing = new Compartment();

  function sizeTheme(size: number) {
    return EditorView.theme({ "&": { fontSize: `${size}px` } });
  }

  let container: HTMLDivElement;
  let view: EditorView | undefined;

  // Each open tab keeps its own EditorState — content, selection, and
  // undo history together — so switching tabs feels like switching
  // windows, not reloading a document. The editor itself stays a
  // single mounted instance; only the state object underneath it
  // swaps. Suppressed while a swap is in flight so the resulting
  // "document changed" update doesn't get reported as a user edit.
  const tabStates = new Map<string, EditorState>();
  let currentTabId: string | undefined;
  let suppressChangeEvents = false;

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
        wrapping.of(lineWrap ? EditorView.lineWrapping : []),
        sizing.of(sizeTheme(fontSize)),
        ...(text.includes("\r\n") ? [EditorState.lineSeparator.of("\r\n")] : []),
        EditorView.updateListener.of((update) => {
          if (update.docChanged && !suppressChangeEvents) {
            onchange(update.state.sliceDoc());
          }
        }),
        EditorView.theme({
          "&": { height: "100%" },
          ".cm-scroller": { fontFamily: "var(--font-mono, monospace)" },
          "&.cm-focused": { outline: "none" },
        }),
      ],
    });
  }

  // Switches the mounted editor to `id`'s state, caching the outgoing
  // tab's live state first so its selection and undo history survive
  // coming back to it. A tab not seen before starts fresh.
  function loadTab(id: string, text: string) {
    if (!view) return;

    if (currentTabId !== undefined) tabStates.set(currentTabId, view.state);

    const cached = tabStates.get(id);
    suppressChangeEvents = true;
    view.setState(cached && cached.sliceDoc() === text ? cached : stateFor(text));
    suppressChangeEvents = false;

    currentTabId = id;
    view.focus();
  }

  /** Drops a closed tab's cached editor state. */
  export function forgetTab(id: string) {
    tabStates.delete(id);
  }

  onMount(() => {
    view = new EditorView({ state: stateFor(value), parent: container });
    currentTabId = tabId;
    view.focus();
    return () => view?.destroy();
  });

  $effect(() => {
    view?.dispatch({ effects: theme.reconfigure(dark ? oneDark : []) });
  });

  $effect(() => {
    view?.dispatch({
      effects: [
        wrapping.reconfigure(lineWrap ? EditorView.lineWrapping : []),
        sizing.reconfigure(sizeTheme(fontSize)),
      ],
    });
  });

  // Switching tabs swaps in that tab's cached state; staying on the
  // same tab but seeing different text (an external reload) resets
  // just that tab's editor state, including its undo history.
  $effect(() => {
    if (!view) return;

    if (tabId !== currentTabId) {
      loadTab(tabId, value);
    } else if (value !== view.state.sliceDoc()) {
      suppressChangeEvents = true;
      view.setState(stateFor(value));
      suppressChangeEvents = false;
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

  /** Undoes the last edit; routed from the native Edit menu. */
  export function undoEdit() {
    if (view) undo(view);
  }

  export function redoEdit() {
    if (view) redo(view);
  }

  /** The editor's scroll offset, for session persistence. */
  export function getScrollTop(): number {
    return view?.scrollDOM.scrollTop ?? 0;
  }

  export function setScrollTop(top: number) {
    if (view) view.scrollDOM.scrollTop = top;
  }

  /**
   * Selects a match's text (1-based line, 0-based character offsets
   * within it) and scrolls it to the center of the viewport — how a
   * full-text search result is opened. Clamped to the document's
   * actual bounds so a stale result from a file edited since the
   * search ran can't request a position that no longer exists.
   */
  export function revealMatch(line: number, matchStart: number, matchEnd: number) {
    if (!view) return;

    const lineInfo = view.state.doc.line(Math.min(Math.max(line, 1), view.state.doc.lines));
    const from = Math.min(lineInfo.from + matchStart, lineInfo.to);
    const to = Math.min(lineInfo.from + matchEnd, lineInfo.to);

    view.dispatch({
      selection: { anchor: from, head: to },
      effects: EditorView.scrollIntoView(from, { y: "center" }),
    });
    view.focus();
  }
</script>

<div bind:this={container} class="h-full min-h-0 overflow-hidden"></div>
