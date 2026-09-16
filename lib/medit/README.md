# medit editing core

Adapted from the owner-provided local medit repository at
`64b6e6a407380e30a00bb88ad22dd50d2101d378`, `src/buffer.zig` and
`src/uwidth.zig`. No license file was present in that source checkout.

Moss retains the UTF-8 positions, line storage, range extraction, and
Unicode navigation/width helpers. Buffer loading is transactional and preserves
all newline bytes instead of synthesizing a trailing newline or removing CR.
CRLF pairs remain byte-exact but form one navigation/deletion boundary; a
standalone CR remains literal. The editor continues local newline style and
indentation on Enter. The host UI, SDL, filesystem, subprocess, and LSP
dependencies are not copied, nor the LSP position-encoding helpers.
`../editor.zig` supplies bounded transactional edit history and selection state.
Unicode navigation is the upstream pragmatic combining-mark subset, not full
Unicode grapheme segmentation.
