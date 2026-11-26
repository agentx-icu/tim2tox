# Message annotations

`FfiChatService.sendTextWithResult` and `sendGroupTextWithResult` accept optional
`cloudCustomData` containing a JSON object of up to 1,200 UTF-8 bytes. A queued
message keeps its text and metadata in the same offline queue entry. The
`annotationDelivered` result reports local transport acceptance. It does not
confirm that the peer received the annotation or runs a compatible client.

The sender uses the ordinary Tox text or ACTION packet and sends the metadata
separately. Clients without annotation support can still display the original
text. Legacy conferences have no annotation channel. A Dart build paired with
an older native library falls back to the ordinary text send.

## Direct messages

Normal and lossless custom packets from one friend are delivered in order on
the same Tox channel. The sender serializes its text sends and uses control
packet 184, type 5, to bracket the original Tox text fragments:

| Body | Bytes after the phase byte |
| --- | --- |
| Begin (`0x01`) | 8-byte nonce, 2-byte fragment count |
| Commit (`0x02`) | 8-byte nonce, raw UTF-8 JSON object |

Integers are big-endian. The sender emits a commit only after every fragment
was accepted. The receiver accepts it only for the authenticated sender's
matching bracket with exactly the advertised fragment count. The first
fragment's local message ID identifies the row that receives the annotation.

## NGC groups

Group packet kind 5 carries the 4-byte big-endian Tox group message ID of the
first fragment, followed by the raw UTF-8 JSON object. The receiver derives the
group and per-group sender key from the authenticated Tox callback. The tuple
identifies the row even when people send identical text, and either the text or
the annotation may arrive first.

The receiver keeps at most 64 correlation entries with a 30-second lifetime.
An annotation updates the existing `ChatMessage.cloudCustomData` and emits
`messageUpdates`. It never creates a new message, advances unread state, or
generates a second notification.
