`timescale 1ns/1ps
module auth_fsm_plain #(
  parameter int PKW = 256
)(
  input  logic           clk,
  input  logic           rst_n,

  input  logic           start,       // one-shot pulse
  input  logic           clear,       // optional: reset FSM to IDLE (pulse)
  input  logic [PKW-1:0] pk_input,
  input  logic [PKW-1:0] pk_allow,

  output logic           busy,
  output logic           done,        // 1-cycle pulse when compare completes
  output logic           pk_match,    // latched result of (pk_input == pk_allow)
  output logic           pass         // same as pk_match in MVP
);

  typedef enum logic [1:0] {IDLE=2'b00, BUSY=2'b01, DONE=2'b10} st_t;
  st_t st, nx;

  logic [PKW-1:0] pk_in_lat, pk_ref_lat;
  logic           cmp_res;

  assign cmp_res = (pk_in_lat == pk_ref_lat);

  always_comb begin
    nx   = st;
    case (st)
      IDLE: if (start) nx = BUSY;
      BUSY:            nx = DONE;
      DONE:            nx = IDLE;
      default:         nx = IDLE;
    endcase
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      st       <= IDLE;
      pk_in_lat  <= '0;
      pk_ref_lat <= '0;
      pk_match <= 1'b0;
      pass     <= 1'b0;
      done     <= 1'b0;
      busy     <= 1'b0;
    end else begin
      if (clear) begin
        st       <= IDLE;
        pk_match <= 1'b0;
        pass     <= 1'b0;
        done     <= 1'b0;
        busy     <= 1'b0;
      end else begin
        st   <= nx;
        done <= 1'b0;
        case (st)
          IDLE: begin
            busy <= 1'b0;
            if (start) begin
              pk_in_lat  <= pk_input;
              pk_ref_lat <= pk_allow;
              busy       <= 1'b1;
            end
          end
          BUSY: begin
            pk_match <= cmp_res;
            pass     <= cmp_res;
            busy     <= 1'b0;
          end
          DONE: begin
            done <= 1'b1;
          end
        endcase
      end
    end
  end

endmodule
