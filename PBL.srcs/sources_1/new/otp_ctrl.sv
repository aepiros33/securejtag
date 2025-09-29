`timescale 1ns/1ps
module otp_ctrl #(
  parameter bit        OTP_SOFTLOCK   = 1'b1,                 // LOCK
  parameter logic [2:0]OTP_LCS        = 3'b010,               // DEV
  parameter logic [255:0] OTP_PK_ALLOW= 256'h0123_4567_89AB_CDEF_FEED_FACE_CAFE_BABE_1122_3344_5566_7788_99AA_BBCC_DDEE_FF00
)(
  input  logic        clk, rst_n,
  output logic        soft_lock_fuse_o,
  output logic [2:0]  lcs_fuse_o,
  output logic [255:0]pk_allow_fuse_o
);
  // RO "fuse" 레지스터(리셋 시 파라미터 로드)
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      soft_lock_fuse_o <= OTP_SOFTLOCK;
      lcs_fuse_o       <= OTP_LCS;
      pk_allow_fuse_o  <= OTP_PK_ALLOW;
    end else begin
      // no writes (RO)
      soft_lock_fuse_o <= soft_lock_fuse_o;
      lcs_fuse_o       <= lcs_fuse_o;
      pk_allow_fuse_o  <= pk_allow_fuse_o;
    end
  end
endmodule
