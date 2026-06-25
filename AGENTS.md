stream parser lives src/html/stream.zig. zero DOM. callback returns !bool; false skips subtree.
scan-only: byte loop for '<' beats memchr on dense HTML. end/bang/pi tag '>' use 32-byte linear probe then memchr.
