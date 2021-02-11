// Copyright lowRISC contributors.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// Pinmux toplevel.
//

`include "prim_assert.sv"

module pinmux
  import pinmux_pkg::*;
  import pinmux_reg_pkg::*;
(
  input                            clk_i,
  input                            rst_ni,
  // Slow always-on clock
  input                            clk_aon_i,
  input                            rst_aon_ni,
  // Wakeup request, running on clk_aon_i
  output logic                     aon_wkup_req_o,
  output logic                     usb_wkup_req_o,
  // Sleep enable, running on clk_i
  input                            sleep_en_i,
  // Strap sample request
  input  lc_strap_req_t            lc_pinmux_strap_i,
  output lc_strap_rsp_t            lc_pinmux_strap_o,
  output dft_strap_test_req_t      dft_strap_test_o,
  // Direct USB connection
  input                            usb_out_of_rst_i,
  input                            usb_aon_wake_en_i,
  input                            usb_aon_wake_ack_i,
  input                            usb_suspend_i,
  output usbdev_pkg::awk_state_t   usb_state_debug_o,
  // Bus Interface (device)
  input  tlul_pkg::tl_h2d_t        tl_i,
  output tlul_pkg::tl_d2h_t        tl_o,
  // Muxed Peripheral side
  input        [NMioPeriphOut-1:0] periph_to_mio_i,
  input        [NMioPeriphOut-1:0] periph_to_mio_oe_i,
  output logic [NMioPeriphIn-1:0]  mio_to_periph_o,
  // Dedicated Peripheral side
  input        [NDioPads-1:0]      periph_to_dio_i,
  input        [NDioPads-1:0]      periph_to_dio_oe_i,
  output logic [NDioPads-1:0]      dio_to_periph_o,
  // Pad side
  // MIOs
  output logic [NMioPads-1:0][AttrDw-1:0] mio_attr_o,
  output logic [NMioPads-1:0]             mio_out_o,
  output logic [NMioPads-1:0]             mio_oe_o,
  input        [NMioPads-1:0]             mio_in_i,
  // DIOs
  output logic [NDioPads-1:0][AttrDw-1:0] dio_attr_o,
  output logic [NDioPads-1:0]             dio_out_o,
  output logic [NDioPads-1:0]             dio_oe_o,
  input        [NDioPads-1:0]             dio_in_i
);

  ////////////////////////////
  // Parameters / Constants //
  ////////////////////////////

  // TODO: these need to be parameterizable via topgen at some point.
  // They have been placed here such that they do not generate
  // warnings in the C header generation step, since logic is not supported
  // as a data type yet.
  localparam logic [pinmux_reg_pkg::NDioPads-1:0]      DioPeriphHasWkup
                   = {pinmux_reg_pkg::NDioPads{1'b1}};

  //////////////////////////////////
  // Regfile Breakout and Mapping //
  //////////////////////////////////

  pinmux_reg2hw_t reg2hw;
  pinmux_hw2reg_t hw2reg;

  pinmux_reg_top u_reg (
    .clk_i  ,
    .rst_ni ,
    .tl_i   ,
    .tl_o   ,
    .reg2hw ,
    .hw2reg ,
    .devmode_i(1'b1)
  );

  /////////////////////////////
  // Pad attribute registers //
  /////////////////////////////

  logic [NDioPads-1:0][AttrDw-1:0] dio_pad_attr_q;
  logic [NMioPads-1:0][AttrDw-1:0] mio_pad_attr_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin : p_regs
    if (!rst_ni) begin
      dio_pad_attr_q <= '0;
      mio_pad_attr_q <= '0;
    end else begin
      // dedicated pads
      for (int kk = 0; kk < NDioPads; kk++) begin
        if (reg2hw.dio_pad_attr[kk].qe) begin
          dio_pad_attr_q[kk] <= reg2hw.dio_pad_attr[kk].q;
        end
      end
      // muxed pads
      for (int kk = 0; kk < NMioPads; kk++) begin
        if (reg2hw.mio_pad_attr[kk].qe) begin
          mio_pad_attr_q[kk] <= reg2hw.mio_pad_attr[kk].q;
        end
      end
    end
  end

  ////////////////////////
  // Connect attributes //
  ////////////////////////

  // TODO: rework the WARL behavior
  for (genvar k = 0; k < NDioPads; k++) begin : gen_dio_attr
    logic [AttrDw-1:0] warl_mask;
    assign warl_mask = '0;
    assign dio_attr_o[k]            = dio_pad_attr_q[k] & warl_mask;
    assign hw2reg.dio_pad_attr[k].d = dio_pad_attr_q[k] & warl_mask;
  end

  for (genvar k = 0; k < NMioPads; k++) begin : gen_mio_attr
    logic [AttrDw-1:0] warl_mask;
    assign warl_mask = '0;
    assign mio_attr_o[k]            = mio_pad_attr_q[k] & warl_mask;
    assign hw2reg.mio_pad_attr[k].d = mio_pad_attr_q[k] & warl_mask;
  end


  ///////////////////////////////////////
  // USB wake detect module connection //
  ///////////////////////////////////////

  // Dedicated Peripheral side
  usbdev_aon_wake u_usbdev_aon_wake (
    .clk_aon_i,
    .rst_aon_ni,

    // input signals for resume detection
    .usb_dp_async_alw_i(dio_to_periph_o[UsbDpSel]),
    .usb_dn_async_alw_i(dio_to_periph_o[UsbDnSel]),
    .usb_dppullup_en_alw_i(dio_oe_o[UsbDpPullUpSel]),
    .usb_dnpullup_en_alw_i(dio_oe_o[UsbDnPullUpSel]),

    // tie this to something from usbdev to indicate its out of reset
    .usb_out_of_rst_alw_i(usb_out_of_rst_i),
    .usb_aon_wake_en_upwr_i(usb_aon_wake_en_i),
    .usb_aon_woken_upwr_i(usb_aon_wake_ack_i),
    .usb_suspended_upwr_i(usb_suspend_i),

    // wake/powerup request
    .wake_req_alw_o(usb_wkup_req_o),
    .state_debug_o(usb_state_debug_o)
  );

  /////////////////////////
  // Retention Registers //
  /////////////////////////

  logic sleep_en_q, sleep_trig;

  logic [NMioPads-1:0] mio_sleep_trig;
  logic [NMioPads-1:0] mio_out_retreg_d, mio_oe_retreg_d;
  logic [NMioPads-1:0] mio_out_retreg_q, mio_oe_retreg_q;

  logic [NDioPads-1:0] dio_sleep_trig;
  logic [NDioPads-1:0] dio_out_retreg_d, dio_oe_retreg_d;
  logic [NDioPads-1:0] dio_out_retreg_q, dio_oe_retreg_q;

  // Sleep entry trigger
  assign sleep_trig = sleep_en_i & ~sleep_en_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin : p_sleep
    if (!rst_ni) begin
      sleep_en_q       <= 1'b0;
      mio_out_retreg_q <= '0;
      mio_oe_retreg_q  <= '0;
      dio_out_retreg_q <= '0;
      dio_oe_retreg_q  <= '0;
    end else begin
      sleep_en_q <= sleep_en_i;

      // MIOs
      for (int k = 0; k < NMioPads; k++) begin
        if (mio_sleep_trig[k]) begin
          mio_out_retreg_q[k] <= mio_out_retreg_d[k];
          mio_oe_retreg_q[k]  <= mio_oe_retreg_d[k];
        end
      end

      // DIOs
      for (int k = 0; k < NDioPads; k++) begin
        if (dio_sleep_trig[k]) begin
          dio_out_retreg_q[k] <= dio_out_retreg_d[k];
          dio_oe_retreg_q[k]  <= dio_oe_retreg_d[k];
        end
      end
    end
  end

  /////////////////////
  // MIO Input Muxes //
  /////////////////////

  localparam int AlignedMuxSize = (NMioPads + 2 > NDioPads) ? 2**$clog2(NMioPads + 2) :
                                                              2**$clog2(NDioPads);

  // stack input and default signals for convenient indexing below possible defaults: constant 0 or
  // 1. make sure mux is aligned to a power of 2 to avoid Xes.
  logic [AlignedMuxSize-1:0] mio_data_mux;
  assign mio_data_mux = AlignedMuxSize'({mio_in_i, 1'b1, 1'b0});

  for (genvar k = 0; k < NMioPeriphIn; k++) begin : gen_mio_periph_in
    // index using configured insel
    assign mio_to_periph_o[k] = mio_data_mux[reg2hw.mio_periph_insel[k].q];
  end

  //////////////////////
  // MIO Output Muxes //
  //////////////////////

  // stack output data/enable and default signals for convenient indexing below
  // possible defaults: 0, 1 or 2 (high-Z). make sure mux is aligned to a power of 2 to avoid Xes.
  logic [2**$clog2(NMioPeriphOut+3)-1:0] periph_data_mux, periph_oe_mux;
  assign periph_data_mux  = $bits(periph_data_mux)'({periph_to_mio_i, 1'b0, 1'b1, 1'b0});
  assign periph_oe_mux    = $bits(periph_oe_mux)'({periph_to_mio_oe_i,  1'b0, 1'b1, 1'b1});

  for (genvar k = 0; k < NMioPads; k++) begin : gen_mio_out
    // Check individual sleep enable status bits
    assign mio_out_o[k] = reg2hw.mio_pad_sleep_status[k].q ?
                          mio_out_retreg_q[k]              :
                          periph_data_mux[reg2hw.mio_outsel[k].q];

    assign mio_oe_o[k]  = reg2hw.mio_pad_sleep_status[k].q ?
                          mio_oe_retreg_q[k]               :
                          periph_oe_mux[reg2hw.mio_outsel[k].q];

    // latch state when going to sleep
    // 0: drive low
    // 1: drive high
    // 2: high-z
    // 3: previous value
    assign mio_out_retreg_d[k] = (reg2hw.mio_pad_sleep_mode[k].q == 0) ? 1'b0 :
                                 (reg2hw.mio_pad_sleep_mode[k].q == 1) ? 1'b1 :
                                 (reg2hw.mio_pad_sleep_mode[k].q == 2) ? 1'b0 : mio_out_o[k];

    assign mio_oe_retreg_d[k] = (reg2hw.mio_pad_sleep_mode[k].q == 0) ? 1'b1 :
                                (reg2hw.mio_pad_sleep_mode[k].q == 1) ? 1'b1 :
                                (reg2hw.mio_pad_sleep_mode[k].q == 2) ? 1'b0 : mio_oe_o[k];

    // Activate sleep behavior only if it has been enabled
    assign mio_sleep_trig[k] = reg2hw.mio_pad_sleep_en[k].q & sleep_trig;
    assign hw2reg.mio_pad_sleep_status[k].d = 1'b1;
    assign hw2reg.mio_pad_sleep_status[k].de = mio_sleep_trig[k];
  end

  /////////////////////
  // DIO connections //
  /////////////////////

  // Inputs are just fed through
  assign dio_to_periph_o = dio_in_i;

  for (genvar k = 0; k < NDioPads; k++) begin : gen_dio_out
    // Check individual sleep enable status bits
    assign dio_out_o[k] = reg2hw.dio_pad_sleep_status[k].q ?
                          dio_out_retreg_q[k]              :
                          periph_to_dio_i[k];

    assign dio_oe_o[k]  = reg2hw.dio_pad_sleep_status[k].q ?
                          dio_oe_retreg_q[k]               :
                          periph_to_dio_oe_i[k];

    // latch state when going to sleep
    // 0: drive low
    // 1: drive high
    // 2: high-z
    // 3: previous value
    assign dio_out_retreg_d[k] = (reg2hw.dio_pad_sleep_mode[k].q == 0) ? 1'b0 :
                                 (reg2hw.dio_pad_sleep_mode[k].q == 1) ? 1'b1 :
                                 (reg2hw.dio_pad_sleep_mode[k].q == 2) ? 1'b0 : dio_out_o[k];

    assign dio_oe_retreg_d[k] = (reg2hw.dio_pad_sleep_mode[k].q == 0) ? 1'b1 :
                                (reg2hw.dio_pad_sleep_mode[k].q == 1) ? 1'b1 :
                                (reg2hw.dio_pad_sleep_mode[k].q == 2) ? 1'b0 : dio_oe_o[k];

    // Activate sleep behavior only if it has been enabled
    assign dio_sleep_trig[k] = reg2hw.dio_pad_sleep_en[k].q & sleep_trig;
    assign hw2reg.dio_pad_sleep_status[k].d = 1'b1;
    assign hw2reg.dio_pad_sleep_status[k].de = dio_sleep_trig[k];
  end

  //////////////////////
  // Wakeup detectors //
  //////////////////////

  logic [NWkupDetect-1:0] aon_wkup_req;
  logic [AlignedMuxSize-1:0] dio_data_mux;

  // Only connect DIOs that are not excempt
  for (genvar k = 0; k < NDioPads; k++) begin : gen_dio_wkup
    if (DioPeriphHasWkup[k]) begin : gen_dio_wkup_connect
      assign dio_data_mux[k] = dio_in_i[k];
    end else begin : gen_dio_wkup_tie_off
      assign dio_data_mux[k] = 1'b0;
    end
  end

  for (genvar k = NDioPads; k < AlignedMuxSize; k++) begin : gen_dio_data_mux_tie_off
      assign dio_data_mux[k] = 1'b0;
  end

  for (genvar k = 0; k < NWkupDetect; k++) begin : gen_wkup_detect
    logic pin_value;
    assign pin_value = (reg2hw.wkup_detector[k].miodio.q)           ?
                       dio_data_mux[reg2hw.wkup_detector_padsel[k]] :
                       mio_data_mux[reg2hw.wkup_detector_padsel[k]];

    pinmux_wkup i_pinmux_wkup (
      .clk_i,
      .rst_ni,
      .clk_aon_i,
      .rst_aon_ni,
      // config signals. these are synched to clk_aon internally
      .wkup_en_i          ( reg2hw.wkup_detector_en[k].q                ),
      .filter_en_i        ( reg2hw.wkup_detector[k].filter.q            ),
      .wkup_mode_i        ( wkup_mode_e'(reg2hw.wkup_detector[k].mode.q)),
      .wkup_cnt_th_i      ( reg2hw.wkup_detector_cnt_th[k].q            ),
      .pin_value_i        ( pin_value                                   ),
      // cause reg signals. these are synched from/to clk_aon internally
      .wkup_cause_valid_i ( reg2hw.wkup_cause[k].qe                     ),
      .wkup_cause_data_i  ( reg2hw.wkup_cause[k].q                      ),
      .wkup_cause_data_o  ( hw2reg.wkup_cause[k].d                      ),
      // wakeup request signals on clk_aon (level encoded)
      .aon_wkup_req_o     ( aon_wkup_req[k]                             )
    );
  end

  // OR' together all wakeup requests
  assign aon_wkup_req_o = |aon_wkup_req;

  ////////////////////
  // Strap Sampling //
  ////////////////////

  logic [NLcStraps-1:0] lc_strap_taps;
  logic [NDFTStraps-1:0] dft_strap_taps;
  lc_strap_rsp_t lc_strap_d, lc_strap_q;
  dft_strap_test_req_t dft_strap_test_d, dft_strap_test_q;

  for (genvar k = 0; k < NLcStraps; k++) begin : gen_lc_strap_taps
    assign lc_strap_taps[k] = mio_in_i[LcStrapPos[k]];
  end

  for (genvar k = 0; k < NDFTStraps; k++) begin : gen_dft_strap_taps
    assign dft_strap_taps[k] = mio_in_i[DftStrapPos[k]];
  end

  assign lc_pinmux_strap_o = lc_strap_q;
  assign lc_strap_d = (lc_pinmux_strap_i.sample_pulse)      ?
                      '{valid: 1'b1, straps: lc_strap_taps} :
                      lc_strap_q;

  // DFT straps are triggered by the same LC sampling pulse
  assign dft_strap_test_o = dft_strap_test_q;
  assign dft_strap_test_d = (lc_pinmux_strap_i.sample_pulse) ?
                            '{valid: 1'b1, straps: dft_strap_taps} :
                            dft_strap_test_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin : p_strap_sample
    if (!rst_ni) begin
      lc_strap_q       <= '0;
      dft_strap_test_q <= '0;
    end else begin
      lc_strap_q       <= lc_strap_d;
      dft_strap_test_q <= dft_strap_test_d;
    end
  end

  ////////////////
  // Assertions //
  ////////////////

  `ASSERT_KNOWN(TlDValidKnownO_A, tl_o.d_valid)
  `ASSERT_KNOWN(TlAReadyKnownO_A, tl_o.a_ready)
  // `ASSERT_KNOWN(MioToPeriphKnownO_A, mio_to_periph_o)
  `ASSERT_KNOWN(MioOeKnownO_A, mio_oe_o)
  // `ASSERT_KNOWN(DioToPeriphKnownO_A, dio_to_periph_o)
  `ASSERT_KNOWN(DioOeKnownO_A, dio_oe_o)
  `ASSERT_KNOWN(LcPinmuxStrapKnownO_A, lc_pinmux_strap_o)

  // TODO: need to check why some outputs are not valid (e.g. SPI device SDO)
  // for (genvar k = 0; k < NMioPads; k++) begin : gen_mio_known_if
  //   `ASSERT_KNOWN_IF(MioOutKnownO_A, mio_out_o[k], mio_oe_o[k])
  // end

  // for (genvar k = 0; k < NDioPads; k++) begin : gen_dio_known_if
  //   `ASSERT_KNOWN_IF(DioOutKnownO_A, dio_out_o[k], dio_oe_o[k])
  // end

  `ASSERT_KNOWN(MioKnownO_A, mio_attr_o)
  `ASSERT_KNOWN(DioKnownO_A, dio_attr_o)

  // running on slow AON clock
  `ASSERT_KNOWN(AonWkupReqKnownO_A, aon_wkup_req_o, clk_aon_i, !rst_aon_ni)

endmodule : pinmux
