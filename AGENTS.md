stream parser lives src/html/stream.zig. zero DOM. callback returns !bool; false skips subtree.
no-event config (all emit/include flags off) short-circuits to O(1): no scanning at all.
