-- Detect Phorge/Phabricator Remarkup files.
--
-- Remarkup has no canonical file extension of its own -- it's normally
-- typed inline into comment boxes and wiki pages, not saved as a file.
-- ".remarkup" is a Phorge object saved out of an "arcanist://" buffer.
--
-- The other place it hits disk is when `arc` (Arcanist, Phorge's CLI)
-- shells out to $EDITOR on a temp file for a revision message or update
-- comment. It always writes an unrandomized basename (no extension) into
-- a randomly-named temp directory, via `PhutilInteractiveEditor::setName()`
-- in arcanist/src/workflow/ArcanistDiffWorkflow.php and
-- ArcanistPatchWorkflow.php:
--
--   $TMPDIR/edit.<random>/differential-edit-revision-info   -- `arc diff --edit` (title/summary/test plan)
--   $TMPDIR/edit.<random>/differential-update-comments      -- `arc diff` comment-on-update prompt
--   $TMPDIR/edit.<random>/new-commit                        -- `arc diff` initial commit message
--   $TMPDIR/edit.<random>/arcanist-patch-commit-message      -- `arc patch`
--
-- `$TMPDIR` itself can't be pinned down: it's PHP's sys_get_temp_dir(),
-- which is *not* reliably "/tmp" -- on macOS it's a per-session directory
-- like "/var/folders/xx/xxxxxxxxxxxxxxxxxxxxxxxx/T/", assigned by the OS.
-- What Filesystem::createTemporaryDirectory('edit.') *does* guarantee,
-- regardless of $TMPDIR, is that the immediate parent directory is always
-- prefixed "edit." -- so patterns below require ".../edit.<random>/"
-- right before the basename, without caring what precedes it.
vim.filetype.add({
    extension = {
        remarkup = 'remarkup',
    },
    pattern = {
        ['.*/edit%.[^/]+/differential%-edit%-revision%-info'] = 'remarkup',
        ['.*/edit%.[^/]+/differential%-update%-comments'] = 'remarkup',
        ['.*/edit%.[^/]+/new%-commit'] = 'remarkup',
        ['.*/edit%.[^/]+/arcanist%-patch%-commit%-message'] = 'remarkup',
    },
})
