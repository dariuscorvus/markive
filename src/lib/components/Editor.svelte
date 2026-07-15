<script lang="ts">
  import { markdown } from "@codemirror/lang-markdown";
  import { EditorState } from "@codemirror/state";
  import { EditorView } from "@codemirror/view";
  import { basicSetup } from "codemirror";
  import { onMount } from "svelte";

  let {
    value,
    onchange,
  }: {
    value: string;
    onchange: (value: string) => void;
  } = $props();

  let container: HTMLDivElement;
  let view: EditorView | undefined;

  // CodeMirror joins lines with "\n" unless told otherwise; a CRLF
  // document must round-trip byte-identically.
  function stateFor(text: string): EditorState {
    return EditorState.create({
      doc: text,
      extensions: [
        basicSetup,
        markdown(),
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

  // A new document (different text than the editor holds) resets the
  // editor state, including its undo history.
  $effect(() => {
    if (view && value !== view.state.sliceDoc()) {
      view.setState(stateFor(value));
      view.focus();
    }
  });
</script>

<div bind:this={container} class="h-full min-h-0 overflow-hidden"></div>
