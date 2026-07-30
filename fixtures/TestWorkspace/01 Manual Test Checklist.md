# Manual release test

Test a disposable copy of this workspace. File operations deliberately rename, move, and trash files.

## Open and navigate

- [ ] Open the workspace and confirm `00 Start Here` is selected.
- [ ] Switch between flat and tree views.
- [ ] Expand every folder. `Empty Folder` remains visible.
- [ ] Select a Markdown file in the tree and confirm it opens.
- [ ] Confirm `.hidden-note.md` is hidden by default.
- [ ] Enable hidden files and confirm `.hidden-note.md` appears.
- [ ] Use Quick Open to find `Reference`.
- [ ] Search for `release-smoke-token` and confirm `Notes/Linked Note.md` is returned.
- [ ] Follow a wikilink, then use Back and Forward.

## Editing and file state

- [ ] Edit `Notes/Linked Note.md` and confirm its modified state is visible.
- [ ] Switch documents and confirm the edit is retained.
- [ ] Create a Markdown file.
- [ ] Rename the new file.
- [ ] Create and rename a folder.
- [ ] Move the new file into that folder.
- [ ] Drag the file onto another folder.
- [ ] Create a same-named file in the destination, then try the move again. Both files remain intact.
- [ ] Trash the new file and confirm it leaves the workspace.

## Link-preserving moves

- [ ] Open `Projects/Move Source.md` and follow its links to `Projects/Target.md`.
- [ ] Move `Projects/Target.md` into a new folder.
- [ ] Confirm the Markdown link and wikilink in `Move Source.md` are updated.
- [ ] Confirm Back, Forward, Favorites, open documents, and search still resolve the moved file.

## Side-by-side documents

- [ ] Open `Notes/Reference.md` beside `Notes/Linked Note.md`.
- [ ] Give each view a different scroll position and presentation mode.
- [ ] Open an already visible document and confirm its existing view receives focus.
- [ ] Follow a link in the current view.
- [ ] Follow a link into a new adjacent view.
- [ ] Quit and reopen Markive. The arrangement and independent view state are restored.
- [ ] Confirm an edited document still receives native unsaved-change protection.

## Rendering

- [ ] `00 Start Here.md` renders the SVG image.
- [ ] Its whole-file, heading, and block embeds render the expected content.
- [ ] `Rendering/Failure States.md` shows clear missing, circular, missing-heading, and depth-limit placeholders.
- [ ] `Notes/Reference.md` renders repeated footnote references with distinct backlinks.
- [ ] Footnote links work with the keyboard in both directions.
- [ ] Inline and block math render without a network connection.
- [ ] Copy rendered math and confirm the pasted text retains its dollar-delimited source.
- [ ] The invalid expression remains visible with `Could not render math`.
- [ ] The HTML-looking math source does not create a script element.

## Workspace boundaries

- [ ] Expanding `Loop` does not recurse forever.
- [ ] Search, Quick Open, and the knowledge index follow the hidden-file setting.
- [ ] Embedded files do not expose anything outside this workspace.
