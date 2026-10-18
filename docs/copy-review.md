# Cold-read review of user-facing words

Every label, button, link, menu item, sheet title, banner, notice and empty
state a change adds or rewords gets a **cold read** before it is pushed. A
design review does not replace it.

## Why this exists

The remote sessions work went through many design reviews (visual, UX flow,
copy, final reads) and still shipped a Hosts card row reading
`Test connection  Sessions…  Turn off`. The owner had to ask what
"Sessions…" opens and how to remove a host. Every review missed it, for
reasons that will recur unless the process changes:

- **The reviewers knew too much.** Each was handed the design doc, the
  ledger and the previous rounds, so it already knew what "Sessions…" opens.
  Nobody read the words the way a first-time user does.
- **The questions were about looks, not meaning.** The prompts asked about
  layout, alignment, contrast, consistency with the spec and em-dashes.
  None asked "what would a user think this does?".
- **Reviews pushed labels shorter.** "Sessions on masterblaster-mentes…" was
  cut to "Sessions…" by a visual review to fix row rhythm, and "Turn off"
  came from a layout decision. Brevity won over meaning, and the next review
  checked that the change landed, not that it still made sense.
- **The author reviewed its own words.** The same model that proposed a
  label was later asked whether the copy was right.
- **Screenshot passes encoded the wording.** Computer-use checks were told
  to look for exact strings, so they confirmed the bad label instead of
  questioning it.
- **No one walked a task.** Screens were reviewed one at a time; nobody
  tried "remove this host" or "see what is still running" end to end.

## The procedure

1. **Extract.** List every new or changed user-facing string with where it
   appears (screen, element: button, link, title, caption, empty state) and
   nothing about what it does. Include its neighbours on screen.
2. **Cold read.** Give that list (and screenshots, if any) to a reviewer
   with **no** access to the repo, design docs, ledgers or earlier reviews.
   Opus or Fable, never the model that wrote the copy. Ask, for each string:
   what do you expect happens or is shown; what would you call it instead if
   it is unclear.
3. **Task walk.** Give the same reviewer three to five plain tasks a user
   would have on that screen ("remove this host", "see what is still
   running on it", "add a host from my ssh config"), and ask which control
   they would use and what they expect to happen.
4. **Compare.** Someone who knows the behaviour marks every string whose
   expected meaning differs from what it does, and every task the reviewer
   could not complete or completed with the wrong control.
5. **Rewrite and repeat** with a fresh cold reader until nothing is
   mismatched. A label is not shortened at the cost of meaning; if it does
   not fit, the layout changes, not the words.
6. **Show the owner** the before/after list for anything user-visible he
   has not already approved.

Screenshot and computer-use passes check that a flow can be done and reads
sensibly. They never assert an exact label, so a bad label is not locked in.

## Prompt for step 2 and 3

> You are seeing a macOS app's screen for the first time. Below is every
> piece of text on it, with where it appears. For each, say what you expect
> it does or shows, in one line, and if it is unclear, what you would call
> it. Then, for each task listed, say which control you would use and what
> you expect to happen. Do not guess generously: if a word could mean two
> things, say so.
