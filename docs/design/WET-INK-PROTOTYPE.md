# Wet Ink, ravens and stickers: running and evaluating them

The design reasoning is in [WET-INK.md](WET-INK.md). This file says how
to run the three pieces, what is real and what is simulated, and what
is not done.

![A send in slow motion: typed, lifting under its header, in flight,
landed wet, glint and drop, drying, dry](wet-ink-filmstrip.png)

Seven stills from one send, slowed ten times.

## Run it

```sh
scripts/build-app.sh --debug
build/Nevermore.app/Contents/MacOS/Nevermore --demo
```

The demo opens on `#launch`, a release-day conversation whose last
message asks you a question. Type an answer and press Return.

A ten-second tour:

1. Type a sentence long enough to wrap, press Return. The words fly
   up, land wet, glint once, and dry when the simulated server answers
   about a second later. A teammate replies to every other message.
2. Demo ▸ Offline (⌃⌘O), then send three short messages. They stay wet,
   each with a drop after its last word.
3. Press ⌘Z (Edit ▸ Undo Send). The last message returns to the
   composer.
4. Demo ▸ Fast Network. The held messages dry one after another.

Then the ravens and the stickers:

5. The sidebar shows a raven on `design` and on Morgan, whose eye is
   lit because it is a direct message. Move the pointer near one.
6. Demo ▸ Receive a Message in Another Conversation (⌃⌘U), a few
   times. A count that grows makes its bird hop; a conversation that
   becomes unread gets a bird from the top edge.
7. Click in the transcript and press Space until the app has taken you
   through every unread conversation. Each bird hops to the unread
   divider and leaves when you have read to the end. After the last
   one the footer says "Nevermore."
8. Hover a message, open the reaction row (Message ▸ React…), and drag
   an emoji onto any message. Then throw one. Then click a chip, and
   drag your own chip away from its message.
9. Demo ▸ Receive a Reaction (⌃⌘R). Every third message you send also
   gets one. ⌘Z after adding a reaction takes it back.

Other things to try: Demo ▸ Slow Network (four seconds of wet ink),
Demo ▸ Unreliable Network (the first attempt fails; the drop holds
still in the alert color above a "Not sent" line, then the retry
dries it), Demo ▸ Receive a Message (⌃⌘M), a click on a drop, and any
theme from View ▸ Theme.

To study the motion frame by frame, slow every animation and the demo
network by a factor:

```sh
build/Nevermore.app/Contents/MacOS/Nevermore --demo -inkTimeScale 8
```

`-inkStill YES` shows what Reduce Motion users get. Settings ▸ General
has the checkbox for the sounds.

## What is real

- Sends go through the same draft acceptance, outbox and transcript
  render as a real account. With a real account the same code runs:
  the words fly on Return, stay wet while the outbox uploads and sends,
  and dry on the server's acknowledgement.
- Pending sends are laid out as messages (header, grouping, rich text)
  instead of the grey "You · Queued" paragraph. They stay out of
  `messages` and `messageRanges`, so message commands cannot target
  something the server does not know.
- `AccountStore.takeBack`, `beginAttempt` and `sendToReview` are
  transactional, and `flush()` changes a send only through them until
  it has claimed it. A send that was taken back cannot leave or
  reappear afterwards, and a send that was claimed cannot be taken
  back. Unit tests cover both orders.
- Sending a multi-line message left the composer at its tall size on
  main, because emptying the shared draft does not resize the editor's
  frame. The prototype resizes it; the flight made the leftover box
  obvious.

- Ravens follow the unread counts the app already has. With a real
  account they need nothing new from the server. A lit eye means a
  direct message, or a mention that arrived while the app was running:
  Raven's unread counts do not say which conversations mention you, so
  mentions from before launch do not light an eye.
- Stickers end in the same `react` call as a click in the reaction
  row. A sticker that the server refuses, or that gets no answer in
  eight seconds, falls off. Only Unicode emoji become stickers.
- Space in the transcript now reads on: Quick Look when the selected
  message has a file, otherwise a page down, otherwise the next
  conversation with a raven. Muted conversations are skipped.
- Clicking a reaction chip toggles your own reaction, as on Raven's
  web client. Edit ▸ Undo takes back a reaction you added, also while
  the transcript has focus.

## What is simulated

- `DemoWire` plays the server in `--demo` only. It claims queued sends
  after the chosen delay, acknowledges them with a message that carries
  the send's batch ID, and posts teammates' answers. Nothing leaves the
  Mac. `--self-check` and `--performance-check` do not create a wire,
  so the demo they run still refuses to send.
- The interactive demo keeps its conversation in its own store
  (`DemoWire`), apart from the `Demo` store of earlier builds.
- In the demo, unread counts follow from your visits, reactions are
  stored on this Mac in Raven's shape, and teammates' messages and
  reactions come from the Demo menu.

## Verified

- `swift test` passes: 82 XCTest cases and 287 Swift Testing tests,
  including 25 new XCTest cases for the flight plan, the wetness
  mapping, the store's take-back, claim and review parking, which
  conversations get a raven, and the sticker's drag, throw and chip
  rules.
- `Nevermore --demo --self-check` passes with no failed check (629
  checks, 22 of them for ravens and stickers).
- By hand, in slow motion and at full speed, in Classic (dark) and
  Lemonade (light, wallpaper): flight with reflow, landing registration,
  glint, drop, per-line drying, the offline cascade, Undo Send from the
  Edit menu, the failed-then-retried state, incoming messages, emoji in
  flight, the motion-off path.

- Ravens, by hand in slow motion, in Classic and Lemonade: the still
  birds and the lit eye, arrival from the top edge, the hop when a
  count grows, the head following the pointer, the hop to the unread
  divider, the departure, Space through every unread conversation, the
  footer line, and the motion-off path.
- Stickers, by hand in slow motion: carry with lean, wash and slot,
  landing, the count roll, a throw, the click arc from the row, chip
  clicks that add and remove, peeling by drag, reactions arriving from
  a teammate, Undo Reaction from the Edit menu, and the motion-off
  path.

- One automated review of the first branch (GLM-5.3) reported six
  defects:
  a stale flush write that could revive a taken-back send, a crash if
  the window closed during a take back, a take back of words still in
  flight, a flight binding to another window's send, a composer left
  invisible after the window moved on, and a shared draft overwritten
  by a take back. All six are fixed; the fixes were not re-reviewed.

## Not verified, not done

- A real Raven server. The live path shares the code but was not run
  against one. This includes realtime mentions lighting an eye and a
  server refusing a sticker.
- The sounds were checked for format and level, not by ear.
- The feel at full speed. The machine used for testing was under heavy
  load from other work, so timing was judged from slowed captures.
- A reaction on a message that has none yet lands in a slot predicted
  at the end of the row. Raven sorts chips by emoji, so the sticker
  can slide a few points to its real place when the chip appears.
- Stickers are pointer-only. Keyboard and VoiceOver users react with
  the commands that existed before; the ravens add nothing to the
  accessibility tree, and the unread labels are unchanged.
- ⌘Z as a key press. The automation tool here could not deliver chords
  to the app; the Edit ▸ Undo Send item it triggers was exercised. The
  drop's menu was opened and read, but its Take Back item, which calls
  the same code, could not be clicked by the tool.
- The drop is a view inside the transcript's text view and is not in
  the accessibility tree. Undo Send and the Outbox window give the same
  commands to VoiceOver and keyboard users. A stalled or blocked send
  also says so in transcript text; a send that is merely held does not.
- Messages taller than the composer, or longer than 160 words, appear
  wet with a glint but do not fly.
- The thread inspector does not show pending sends at all, as on main.
- Take Back against a live server needs a hold (see the design note).
