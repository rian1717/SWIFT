# Attribution

SWIFT stands on prior open-source implementation and reverse-engineering
work. This file records that provenance so downstream users can audit it.

## QShare — implementation foundation

SWIFT began from QShare commit
`2a26e30a978d2344c05f6927c44cedc25fecaf35`, published by kanin-design under
the Zero-Clause BSD License. SWIFT has renamed, modified, documented, and
extended that implementation. The original license notice is reproduced in
[`NOTICE`](../NOTICE).

## NearDrop — protocol reverse engineering

Google's Quick Share / Nearby Share LAN protocol is undocumented. It was
reverse-engineered and written up by **@grishka**, whose specification and
implementation are published at
**[grishka/NearDrop](https://github.com/grishka/NearDrop)** and released into
the public domain under The Unlicense.

The implementation follows that specification. No GPL implementation code is
included. The specification leaves some behaviour implicit — field ordering,
paired-key placeholders, and PIN derivation — so NearDrop remains an important
behavioural reference.

The Unlicense imposes no conditions, so this credit is given because it is
deserved, not because it is required. Without that work this app would not
exist.

## Protobuf schemas

The message definitions descend from Google's `securemessage.proto`,
`securegcm.proto`, `ukey.proto`, `offline_wire_formats.proto` and
`wire_format.proto` (Apache-2.0). SWIFT implements by hand only the subset
of messages the LAN protocol exchanges.

## SWIFT's license

SWIFT's combined work is released under the
[Apache License, Version 2.0](../LICENSE). The upstream 0BSD grant permits use,
modification, and redistribution under these terms; its original notice remains
in [`NOTICE`](../NOTICE).

## Dependencies

None. SWIFT builds against Foundation, Network, CryptoKit, CommonCrypto,
AppKit and SwiftUI — all part of macOS.
