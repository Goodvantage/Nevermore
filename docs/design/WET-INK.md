# Making Nevermore delicious: design note

Nevermore's central loop is small: a message arrives, you read it, you
write one back, it leaves. Three moments in that loop carry feeling:
the send (creation and release), the unread pile (anticipation), and
the reaction (play). Each concept below takes one of them. All three
are built; Wet Ink came first.

## Concept 1: Wet Ink (the send)

**Inspired by** the durable outbox. Nevermore accepts a message locally,
keeps it across crashes and retries it with an immutable key. That is
the client's most careful engineering, and today it shows as a grey
"You · Queued" paragraph.

**What you see and do.** Before: you type in the glass composer. On
Return, every word lifts 5 pt off the glass within one frame, before
any disk write finishes. During: the words fly to the exact pixels they
will occupy in the transcript, each a separate layer, staggered 5 ms
apart, and they reflow in the air from the composer's wrap to the
transcript's wider wrap. They land as real, selectable text in wet ink
(the text color pulled 60% toward the accent), and one glint crosses
the letterforms. After: the message stays wet until the server
acknowledges it, then dries left to right, line after line, 70 ms
apart. While wet, an ink drop sits after the last word; Command-Z
pulls the words back down into the composer.

**"You have to see this."** Go offline, send three messages, reconnect:
they dry one after another, in the order you wrote them.

**Daily use.** The flight takes under half a second and never blocks
typing. Pending messages are laid out exactly as they will be when
sent, so nothing jumps on acknowledgement. State is carried by the
drop as well as by color, and by a line of text when a send fails.
Reduce Motion replaces flight and sweep with a cut.

## Concept 2: The Unkindness (the unread pile)

**Inspired by** the name, the known-watermark unread divider and
Go ▸ Next Unread Conversation. A group of ravens is an unkindness, and
"nevermore" is exactly what an empty unread list says.

**What you see and do.** Before: each unread conversation has a raven,
16 by 14 pt, standing on its sidebar row left of the count. A direct
message or a mention lights its eye in the accent color, and its head
turns toward the pointer within 120 pt, in steps of 15 degrees. Muted
conversations keep their count and get no bird. During: a new message
brings a bird in from the top edge on a curve; it dips 2 pt on landing.
A further message makes it hop. Opening the conversation, the bird hops
across into the transcript and settles on the unread divider, in the
divider's color; once you have read to the end it takes off. Space
pages down and, at the end, carries you to the next conversation a
bird waits on. After: when the last one leaves, a single raven lands
on the connection footer and the footer reads "Nevermore." for four
seconds.

**"You have to see this."** Clear the last unread conversation and the
app says its own name.

**Daily use.** Counts stay digits, so the bird never has to be decoded.
Every flight is under 0.6 s and none delays a click. Next Unread keeps
its menu item and shortcut, and Space still opens Quick Look on an
attachment. Reduce Motion shows a still glyph; VoiceOver hears the
same "3 unread" as before, and the connection state while the footer
says its line.

## Concept 3: Stickers with weight (the reaction)

**Inspired by** one-click quick reactions that already rank the
account's most-used emoji, and reaction chips that are the only objects
in the transcript several people build together.

**What you see and do.** Before: hovering a message offers the reaction
row. During: press an emoji and drag. It lifts to 1.6x with a shadow
6 pt below and leans up to 12 degrees against the drag. The message
under it is washed and shows a dashed slot where the chip will be. Let
go and it drops with a squash (vertical scale 0.82 back to 1 in 180 ms)
and a short thock; the chip's count rolls like an odometer digit.
Release faster than 900 pt/s and it keeps flying, spinning, and sticks
to the message where it comes to rest. After: your chip can be peeled.
Drag it 24 pt away and it lifts off, turns and falls out of the pane.
Clicking any chip adds or removes your own reaction. Other people's
reactions drop into their chips from the top of the pane.

**"You have to see this."** Fling a reaction across the window and it
sticks where it lands.

**Daily use.** A plain click does what it did before, with a 220 ms
arc from the row to the chip. Drag threshold is 6 pt, so a click never
turns into a throw. Command-Z removes the reaction you just added.
Keyboard reaction commands are unchanged; custom emoji react as
before, without the sticker.

## First commitment: Wet Ink

Sending is the action a chat client performs most, so pleasure placed
there is paid out hundreds of times a day, and it is the one moment
where the app takes something you made. The other two concepts decorate
states that are already clear. Wet Ink makes a hidden state clear: the
gap between "I pressed Return" and "the server has it" becomes
a material you can read at a glance and act on. The idea also could not
belong to a client without a durable outbox; ink that is still wet is
only honest if the app really holds the message.

The vocabulary is deliberately small and all of it means something:

- **Lift.** Words leave the glass at once; the composer is free for the
  next sentence while they travel.
- **Flight.** Per word, on a spring (stiffness 300, damping 26), with a
  1.2 degree flutter that settles to zero. Words keep their identity,
  so the eye tracks what was written, not an effect.
- **Wet.** Accepted, not acknowledged. A drop after the last word says
  so without color: it breathes while the outbox works and holds
  still, in the alert color and with a line of plain text, when a send
  needs attention. Clicking it offers Take Back and the outbox.
- **Glint.** One 80 pt highlight crosses the letterforms on landing,
  masked to the glyphs. This is the extravagance; it is 0.55 s long.
- **Dry.** Acknowledged. A soft-edged sweep per line, in writing order.
  Messages from other people arrive already half dry and finish in
  0.35 s, enough to show what is new.
- **Take Back.** Edit ▸ Undo Send while a message is still queued. The
  words peel off the transcript and land in the composer, caret at the
  end, reply target and attachments restored.
- **Sound.** Four synthesized cues of 200 ms or less: lift, landing,
  dry, take back. One checkbox turns them off.

The prototype runs in the app's own demo mode, which previously refused
to send. A simulated wire accepts sends through the real draft and
outbox code, acknowledges them after a chosen delay (fast, slow,
failing once, or held offline), and has teammates answer.

## What I deliberately did not do

- **No feathers, quills or parchment.** The ink is a behavior of the
  text, not a costume for the window. Sixteen themes already supply
  costume; ink, birds and stickers take their colors from whichever is
  active. The raven is the one figure, and it is the size of a digit.
- **No bubbles.** The transcript stays a continuous, selectable
  document. The words travel as text.
- **No hold on live sends.** Against a real server the first attempt
  starts within milliseconds, and after one attempt Take Back is
  unsafe: a lost acknowledgement may mean the message arrived. Live
  Take Back therefore needs the app to hold sends while the Mac is
  offline, or a short hold on every send. Both change delivery, which
  is a product decision, not a flourish. The demo's Offline mode shows
  the first of the two.
- **No changes to the composer's editing.** Two open pull requests
  rework it; the prototype only reads its layout at the moment of
  sending.
- **No bird per message, no flock.** One raven per conversation; the
  count says how many. A sidebar full of birds would be a screensaver.
- **No idle animation.** A perched bird moves only when something
  happens to it or the pointer comes near.
- **No loose stickers.** A sticker always ends as an ordinary reaction
  chip that every Raven client shows the same way. Position, tilt and
  pile-ups are not stored, because the server has nowhere to keep them.
- **No animation on history.** Scrolling back, switching conversations
  and loading earlier messages show dry text immediately. Only what
  happens while you watch is allowed to move.
