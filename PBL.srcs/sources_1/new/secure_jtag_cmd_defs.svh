`ifndef SECURE_JTAG_CMD_DEFS_SVH
`define SECURE_JTAG_CMD_DEFS_SVH
// commands-only header

// Bit indices
`define CMD_BIT_START        0
`define CMD_BIT_RESET_FSM    1
`define CMD_BIT_DEBUG_DONE   2

// Masks
`define CMD_START_MASK       (32'h1 << `CMD_BIT_START)
`define CMD_RESET_FSM_MASK   (32'h1 << `CMD_BIT_RESET_FSM)
`define CMD_DEBUG_DONE_MASK  (32'h1 << `CMD_BIT_DEBUG_DONE)

// Optional helpers
`define CMD_ALL_MASK (`CMD_START_MASK | `CMD_RESET_FSM_MASK | `CMD_DEBUG_DONE_MASK)
`define CMD_FIELD_WIDTH 32

`endif // SECURE_JTAG_CMD_DEFS_SVH
