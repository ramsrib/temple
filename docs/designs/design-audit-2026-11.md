# Design audit, November 2026

Five reviewers each looked at one part of the app (the main window, the overlay
panels, History, Settings and hosts, and the shared visual language), from
today's screenshots and the view code. This is their findings merged. It is a
list of what to change and why, not a plan; nothing here is built.

Not reopened: 30 to 32 pt sidebar rows with 13 pt type, the host name as a
title, two row tones, the tab switcher as a centred list, no counts in
headers, graphite buttons.

## The short version

The app is calm and already looks like one product: one gray system, no blue,
light and dark that match. What makes it feel busy is repetition, not
decoration. The same session is drawn five different ways, the same fact is
often shown two or three times on one screen, and each page invented its own
way to group things. Most of the fixes remove something.

## Five rules to hold everywhere

All five reviewers arrived at these from different directions.

1. **One way to draw a session.** Badge, title, state dot, then project, then
   time, always in that order. A surface may drop fields from the end; it never
   moves them. Today the sidebar, a tab, ⌘K, the tab switcher and History each
   order them differently, and the state dot sits in three places or is
   missing.
2. **One look for "selected".** An inset rounded gray fill, no outline. Hover
   is clearly fainter, and off while the keyboard is driving a list. Today
   there are four looks, and in ⌘K, the new session picker and History two
   rows appear selected at once.
3. **One way to group a page.** A small capitals label with a rule over open
   rows, as Settings and History do. The hosts manager's filled cards and
   Settings' outlined host card go.
4. **Three kinds of button.** Graphite for the main action, gray for the
   others, and one quiet link style. Bold black text is for names and titles
   only; today it also means "click me" (Refresh, Restore, Show 16 more), and
   system buttons survive in the launch failure bar and History.
5. **Four type sizes, two grays.** The views use about twenty sizes and four
   or more grays. Monospace only for things you would paste: paths, commands,
   IDs, addresses.

## The biggest changes, by area

**Main window**

- **Untitled sessions all read "claude: storefront".** The name repeats the
  badge beside it and the project above it, so rows and tabs cannot be told
  apart. This is the largest single source of noise in the window. Show what
  tells a session apart instead: its first request, or when it started.
- **The tab strip repeats the sidebar.** With the sidebar showing, the strip
  lists the same open sessions, in the same order, with the same badge, title
  and dot, and the current session is marked three times. See "Decisions"
  below.
- **The launch failure bar leads with the full command.** The terminal under
  it already prints the reason. One line saying what happened and one action;
  the command a click away.
- **The home page** opens with the app's name and a tagline, then a Continue
  list the sidebar already shows beside it. Keep the Start rows.

**Panels**

- **Three panels, three shapes for the same things.** ⌘K uses two-line rows,
  the tab switcher one-line rows, the project switcher tiles. Use the tab
  switcher's row in all three, and make the project switcher the same centred
  list.
- **The keyboard shortcuts card is a manual.** About forty rows, some of them
  sentences, and a paragraph about hosts. Cut it to short names and keys.
- **Open Session by ID** is the only panel that dims the window and has a
  title, labels and buttons. Folding it into ⌘K was suggested; whether ⌘K
  can take a pasted ID today is not confirmed.

**History**

- **The header says the same thing three times**: a counts line, four tabs
  that restate the counts, and "Showing 6 of 50". Seven controls sit before
  the first row. Keep search and the tabs; move Refresh, the updated time and
  Open Session by ID into a menu.
- **Marks on nearly every row carry no information.** The "in Temple" icon is
  on almost every row and "No transcript" on about half. Mark only the
  exceptions.
- **A row orders its facts unlike the sidebar**, with the project far right
  across an empty gap and the dot mid-row. Rule 1 fixes this.

**Settings and hosts**

- **Settings is ordered by how the app is built.** Three agent sections and
  Hosts fill the first screen; Theme and Terminal font, the settings people
  actually change, are last. Put them first, and make the agents one section
  with two rows each (the Detected row is a status, not a setting).
  "Checking…" shows four times at once; once is enough.
- **Settings, the hosts manager and Add host are three form styles**, and the
  host list is drawn twice in different dress. Rule 3 fixes this.
- **A host's detail shows three rows of "nothing yet"** with buttons at three
  heights. Reduce it to the address, one status line and one row of actions.
  Add host offers four ways forward; keep the field and the list.

## Decisions that are yours

These change how the app works, not only how it looks.

1. **Hide the tabs while the sidebar is showing?** The reviewer's proposal:
   the sidebar is the list of open sessions, the title bar shows only the
   current session's title and +, and tabs appear when the sidebar is hidden.
   It removes the largest duplication in the window. It also removes the tab
   strip's own order, which you kept separate from the sidebar's this week,
   and the close button on a tab.
2. **How should an untitled session be named?** First request, start time, or
   something else.
3. **Remove the Open Session by ID sheet** in favour of pasting into ⌘K.
4. **Cut History to two tabs** (All, Archived), with "Not in Temple" as a
   filter.
5. **Hide the host title when only one machine has sessions.**

## A sensible order

1. The session row (rule 1) and selection (rule 2): they touch every surface
   and make the rest look consistent with little layout change.
2. Untitled session names.
3. History's header and row marks; Settings' order.
4. Grouping and buttons (rules 3 and 4) in the hosts manager and Add host.
5. The decisions above, once made.

The five area reports, with the screenshot each finding refers to, were
working files and are not kept in the repository.
