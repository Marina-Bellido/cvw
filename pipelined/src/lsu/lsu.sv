///////////////////////////////////////////
// lsu.sv
//
// Written: David_Harris@hmc.edu 9 January 2021
// Modified: 
//
// Purpose: Load/Store Unit 
//          Top level of the memory-stage core logic
//          Contains data cache, DTLB, subword read/write datapath, interface to external bus
// 
// A component of the Wally configurable RISC-V project.
// 
// Copyright (C) 2021 Harvey Mudd College & Oklahoma State University
//
// MIT LICENSE
// Permission is hereby granted, free of charge, to any person obtaining a copy of this 
// software and associated documentation files (the "Software"), to deal in the Software 
// without restriction, including without limitation the rights to use, copy, modify, merge, 
// publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons 
// to whom the Software is furnished to do so, subject to the following conditions:
//
//   The above copyright notice and this permission notice shall be included in all copies or 
//   substantial portions of the Software.
//
//   THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, 
//   INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR 
//   PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS 
//   BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, 
//   TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE 
//   OR OTHER DEALINGS IN THE SOFTWARE.
////////////////////////////////////////////////////////////////////////////////////////////////

`include "wally-config.vh"

module lsu (
   input logic              clk, reset,
   input logic              StallM, FlushM, StallW, FlushW,
   output logic             LSUStallM,
   // connected to cpu (controls)
   input logic [1:0]        MemRWM,
   input logic [2:0]        Funct3M,
   input logic [6:0]        Funct7M, 
   input logic [1:0]        AtomicM,
   input logic              TrapM,
   input logic              FlushDCacheM,
   output logic             CommittedM, 
   output logic             SquashSCW,
   output logic             DCacheMiss,
   output logic             DCacheAccess,
   // address and write data
   input logic [`XLEN-1:0]  IEUAdrE,
   (* mark_debug = "true" *)output logic [`XLEN-1:0] IEUAdrM,
   (* mark_debug = "true" *)input logic [`XLEN-1:0]  WriteDataM, 
   output logic [`LLEN-1:0] ReadDataW,
   // cpu privilege
   input logic [1:0]        PrivilegeModeW, 
   input logic              BigEndianM,
   input logic              sfencevmaM,
   // fpu
   input logic [`FLEN-1:0]  FWriteDataM,
   input logic              FpLoadStoreM,
   // faults
   output logic             LoadPageFaultM, StoreAmoPageFaultM,
   output logic             LoadMisalignedFaultM, LoadAccessFaultM,
   // cpu hazard unit (trap)
   output logic             StoreAmoMisalignedFaultM, StoreAmoAccessFaultM,
            // connect to ahb
   (* mark_debug = "true" *)   output logic [`PA_BITS-1:0] LSUBusAdr,
   (* mark_debug = "true" *)   output logic LSUBusRead, 
   (* mark_debug = "true" *)   output logic LSUBusWrite,
   (* mark_debug = "true" *)   input logic LSUBusAck,
   (* mark_debug = "true" *)   input logic LSUBusInit,
   (* mark_debug = "true" *)   input logic [`XLEN-1:0] LSUBusHRDATA,
   (* mark_debug = "true" *)   output logic [`XLEN-1:0] LSUBusHWDATA,
   (* mark_debug = "true" *)   output logic [2:0] LSUBusSize, 
   (* mark_debug = "true" *)   output logic [2:0] LSUBurstType,
   (* mark_debug = "true" *)   output logic [1:0] LSUTransType,
   (* mark_debug = "true" *)   output logic LSUTransComplete,
            // page table walker
   input logic [`XLEN-1:0]  SATP_REGW, // from csr
   input logic              STATUS_MXR, STATUS_SUM, STATUS_MPRV,
   input logic [1:0]        STATUS_MPP,
   input logic [`XLEN-1:0]  PCF,
   input logic              ITLBMissF,
   input logic              InstrDAPageFaultF,
   output logic [`XLEN-1:0] PTE,
   output logic [1:0]       PageType,
   output logic             ITLBWriteF, SelHPTW,
   input var                logic [7:0] PMPCFG_ARRAY_REGW[`PMP_ENTRIES-1:0],
   input var                logic [`XLEN-1:0] PMPADDR_ARRAY_REGW[`PMP_ENTRIES-1:0] // *** this one especially has a large note attached to it in pmpchecker.
  );

  logic [`XLEN+1:0]         IEUAdrExtM;
  logic [`PA_BITS-1:0]      LSUPAdrM;
  logic                     DTLBMissM;
  logic                     DTLBWriteM;
  logic [1:0]               LSURWM;
  logic [1:0]               PreLSURWM;
  logic [2:0]               LSUFunct3M;
  logic [6:0]               LSUFunct7M;
  logic [1:0]               LSUAtomicM;
  (* mark_debug = "true" *)  logic [`XLEN+1:0] 		   PreLSUPAdrM;
  logic [11:0]              LSUAdrE;  
  logic                     CPUBusy;
  logic                     DCacheStallM;
  logic                     CacheableM;
  logic                     BusStall;
  logic                     InterlockStall;
  logic                     IgnoreRequestTLB;
  logic                     BusCommittedM, DCacheCommittedM;
  logic                     SelLSUBusWord;
  logic                     DataDAPageFaultM;
  logic [`XLEN-1:0]         IMWriteDataM, IMAWriteDataM;
  logic [`LLEN-1:0]         IMAFWriteDataM;
  logic [`LLEN-1:0]         ReadDataM;
  logic [(`LLEN-1)/8:0]     ByteMaskM;
  
  // *** TO DO: Burst mode

  flopenrc #(`XLEN) AddressMReg(clk, reset, FlushM, ~StallM, IEUAdrE, IEUAdrM);
  assign IEUAdrExtM = {2'b00, IEUAdrM}; 
  assign LSUStallM = DCacheStallM | InterlockStall | BusStall;

  /////////////////////////////////////////////////////////////////////////////////////////////
  // HPTW and Interlock FSM (only needed if VM supported)
  // MMU include PMP and is needed if any privileged supported
  /////////////////////////////////////////////////////////////////////////////////////////////

  if(`VIRTMEM_SUPPORTED) begin : VIRTMEM_SUPPORTED
    lsuvirtmem lsuvirtmem(.clk, .reset, .StallW, .MemRWM, .AtomicM, .ITLBMissF, .ITLBWriteF,
      .DTLBMissM, .DTLBWriteM, .InstrDAPageFaultF, .DataDAPageFaultM, 
      .TrapM, .DCacheStallM, .SATP_REGW, .PCF,
      .STATUS_MXR, .STATUS_SUM, .STATUS_MPRV, .STATUS_MPP, .PrivilegeModeW,
      .ReadDataM(ReadDataM[`XLEN-1:0]), .WriteDataM, .Funct3M, .LSUFunct3M, .Funct7M, .LSUFunct7M,
      .IEUAdrExtM, .PTE, .IMWriteDataM, .PageType, .PreLSURWM, .LSUAtomicM, .IEUAdrE,
      .LSUAdrE, .PreLSUPAdrM, .CPUBusy, .InterlockStall, .SelHPTW,
      .IgnoreRequestTLB);
  end else begin
    assign {InterlockStall, SelHPTW, PTE, PageType, DTLBWriteM, ITLBWriteF, IgnoreRequestTLB} = '0;
    assign CPUBusy = StallW; assign PreLSURWM = MemRWM; 
    assign LSUAdrE = IEUAdrE[11:0]; 
    assign PreLSUPAdrM = IEUAdrExtM;
    assign LSUFunct3M = Funct3M;  assign LSUFunct7M = Funct7M; assign LSUAtomicM = AtomicM;
    assign IMWriteDataM = WriteDataM;
   end

  // CommittedM tells the CPU's privilege unit the current instruction
  // in the memory stage is a memory operaton and that memory operation is either completed
  // or is partially executed. Partially completed memory operations need to prevent an interrupts.
  // There is not a clean way to restore back to a partial executed instruction.  CommiteedM will
  // delay the interrupt until the LSU is in a clean state.
  assign CommittedM = SelHPTW | DCacheCommittedM | BusCommittedM;

  // MMU and Misalignment fault logic required if privileged unit exists
  // *** DH: This is too strong a requirement.  Separate MMU in `VIRTMEM_SUPPORTED from simpler faults in `ZICSR_SUPPORTED
  if(`ZICSR_SUPPORTED == 1) begin : dmmu
    logic DisableTranslation;
    assign DisableTranslation = SelHPTW | FlushDCacheM;
    mmu #(.TLB_ENTRIES(`DTLB_ENTRIES), .IMMU(0))
    dmmu(.clk, .reset, .SATP_REGW, .STATUS_MXR, .STATUS_SUM, .STATUS_MPRV, .STATUS_MPP,
      .PrivilegeModeW, .DisableTranslation,
      .VAdr(PreLSUPAdrM),
      .Size(LSUFunct3M[1:0]),
      .PTE,
      .PageTypeWriteVal(PageType),
      .TLBWrite(DTLBWriteM),
      .TLBFlush(sfencevmaM),
      .PhysicalAddress(LSUPAdrM),
      .TLBMiss(DTLBMissM),
      .Cacheable(CacheableM), .Idempotent(), .AtomicAllowed(),
      .InstrAccessFaultF(), .LoadAccessFaultM, .StoreAmoAccessFaultM,
      .InstrPageFaultF(),.LoadPageFaultM, .StoreAmoPageFaultM,
      .LoadMisalignedFaultM, .StoreAmoMisalignedFaultM,   // *** these faults need to be supressed during hptw.
      .DAPageFault(DataDAPageFaultM),
         // *** should use LSURWM as this is includes the lr/sc squash. However this introduces a combo loop
         // from squash, depends on LSUPAdrM, depends on TLBHit, depends on these *AccessM inputs.
      .AtomicAccessM(|LSUAtomicM), .ExecuteAccessF(1'b0), 
      .WriteAccessM(PreLSURWM[0]), .ReadAccessM(PreLSURWM[1]),
      .PMPCFG_ARRAY_REGW, .PMPADDR_ARRAY_REGW);

  end else begin
    assign {DTLBMissM, LoadAccessFaultM, StoreAmoAccessFaultM, LoadMisalignedFaultM, StoreAmoMisalignedFaultM} = '0;
    assign {LoadPageFaultM, StoreAmoPageFaultM} = '0;
    assign LSUPAdrM = PreLSUPAdrM;
    assign CacheableM = '1;
  end
  
  /////////////////////////////////////////////////////////////////////////////////////////////
  //  Memory System
  //  Either Data Cache or Data Tightly Integrated Memory or just bus interface
  /////////////////////////////////////////////////////////////////////////////////////////////
  logic [`LLEN-1:0]    LSUWriteDataM, LittleEndianWriteDataM;
  logic [`LLEN-1:0]    ReadDataWordM, LittleEndianReadDataWordM;
  logic [`LLEN-1:0]    ReadDataWordMuxM;
  logic                IgnoreRequest;
  logic                SelUncachedAdr;
  assign IgnoreRequest = IgnoreRequestTLB | TrapM;
  
  // The LSU allows both a DTIM and bus with cache.  However, the PMA decoding presently 
  // use the same UNCORE_RAM_BASE addresss for both the DTIM and any RAM in the Uncore.

  if (`DMEM) begin : dtim
    dtim dtim(.clk, .reset, .LSURWM, .IEUAdrE, .TrapM, .WriteDataM(LSUWriteDataM), //*** fix the dtim FinalWriteData - is this done already?
              .ReadDataWordM(ReadDataWordM[`XLEN-1:0]), .ByteMaskM(ByteMaskM[`XLEN/8-1:0]), .Cacheable(CacheableM));

    // since we have a local memory the bus connections are all disabled.
    // There are no peripherals supported.
    // *** this will have to change to support TIM and bus (DH 8/25/22)
    assign {BusStall, LSUBusWrite, LSUBusRead, BusCommittedM} = '0;   
    assign {DCacheStallM, DCacheCommittedM} = '0;
    assign {DCacheMiss, DCacheAccess} = '0;
  end 
  if (`DBUS) begin : bus  
    localparam integer   WORDSPERLINE = `DCACHE ? `DCACHE_LINELENINBITS/`XLEN : 1;
    localparam integer   LINELEN = `DCACHE ? `DCACHE_LINELENINBITS : `XLEN;
    localparam integer   LOGBWPL = `DCACHE ? $clog2(WORDSPERLINE) : 1;
    logic [LINELEN-1:0]  DLSUBusBuffer;
    logic [`PA_BITS-1:0] DCacheBusAdr;
    logic                DCacheWriteLine;
    logic                DCacheFetchLine;
    logic                DCacheBusAck;
    logic [LOGBWPL-1:0]   WordCount;
            
    busdp #(WORDSPERLINE, LINELEN, LOGBWPL, `DCACHE) busdp(
      .clk, .reset,
      .LSUBusHRDATA, .LSUBusAck, .LSUBusInit, .LSUBusWrite, .LSUBusRead, .LSUBusSize, .LSUBurstType, .LSUTransType, .LSUTransComplete,
      .WordCount, .SelLSUBusWord,
      .LSUFunct3M, .LSUBusAdr, .CacheBusAdr(DCacheBusAdr), .CacheFetchLine(DCacheFetchLine),
      .CacheWriteLine(DCacheWriteLine), .CacheBusAck(DCacheBusAck), .DLSUBusBuffer, .LSUPAdrM,
      .SelUncachedAdr, .IgnoreRequest, .LSURWM, .CPUBusy, .CacheableM,
      .BusStall, .BusCommittedM);

    mux2 #(`LLEN) UnCachedDataMux(.d0(LittleEndianReadDataWordM), .d1({{`LLEN-`XLEN{1'b0}}, DLSUBusBuffer[`XLEN-1:0]}),
      .s(SelUncachedAdr), .y(ReadDataWordMuxM));
    mux2 #(`XLEN) LsuBushwdataMux(.d0(ReadDataWordM[`XLEN-1:0]), .d1(LSUWriteDataM[`XLEN-1:0]),
      .s(SelUncachedAdr), .y(LSUBusHWDATA));
    if(`DCACHE) begin : dcache
      cache #(.LINELEN(`DCACHE_LINELENINBITS), .NUMLINES(`DCACHE_WAYSIZEINBYTES*8/LINELEN),
              .NUMWAYS(`DCACHE_NUMWAYS), .LOGBWPL(LOGBWPL), .WORDLEN(`LLEN), .MUXINTERVAL(`XLEN), .DCACHE(1)) dcache(
        .clk, .reset, .CPUBusy, .SelLSUBusWord, .RW(LSURWM), .Atomic(LSUAtomicM),
        .FlushCache(FlushDCacheM), .NextAdr(LSUAdrE), .PAdr(LSUPAdrM), 
        .ByteMask(ByteMaskM), .WordCount,
        .FinalWriteData(LSUWriteDataM), .Cacheable(CacheableM),
        .CacheStall(DCacheStallM), .CacheMiss(DCacheMiss), .CacheAccess(DCacheAccess),
        .IgnoreRequestTLB, .TrapM, .CacheCommitted(DCacheCommittedM), 
        .CacheBusAdr(DCacheBusAdr), .ReadDataWord(ReadDataWordM), 
        .LSUBusBuffer(DLSUBusBuffer), .CacheFetchLine(DCacheFetchLine), 
        .CacheWriteLine(DCacheWriteLine), .CacheBusAck(DCacheBusAck), .InvalidateCache(1'b0));

    end else begin : passthrough
      assign {ReadDataWordM, DCacheStallM, DCacheCommittedM, DCacheFetchLine, DCacheWriteLine} = '0;
      assign DCacheMiss = CacheableM; assign DCacheAccess = CacheableM;
    end
  end else begin: nobus // block: bus
    assign {LSUBusHWDATA, SelUncachedAdr} = '0; 
    assign ReadDataWordMuxM = LittleEndianReadDataWordM;
  end

  /////////////////////////////////////////////////////////////////////////////////////////////
  // Atomic operations
  /////////////////////////////////////////////////////////////////////////////////////////////
  if (`A_SUPPORTED) begin:atomic
    atomic atomic(.clk, .reset, .StallW, .ReadDataM(ReadDataM[`XLEN-1:0]), .IMWriteDataM, .LSUPAdrM, 
      .LSUFunct7M, .LSUFunct3M, .LSUAtomicM, .PreLSURWM, .IgnoreRequest, 
      .IMAWriteDataM, .SquashSCW, .LSURWM);
  end else begin:lrsc
    assign SquashSCW = 0; assign LSURWM = PreLSURWM; assign IMAWriteDataM = IMWriteDataM;
  end

  if (`F_SUPPORTED) 
    mux2 #(`LLEN) datamux({{{`LLEN-`XLEN}{1'b0}}, IMAWriteDataM}, FWriteDataM, FpLoadStoreM, IMAFWriteDataM);
  else assign IMAFWriteDataM = IMAWriteDataM;
  
  /////////////////////////////////////////////////////////////////////////////////////////////
  // Subword Accesses
  /////////////////////////////////////////////////////////////////////////////////////////////
  subwordread subwordread(.ReadDataWordMuxM, .LSUPAdrM(LSUPAdrM[2:0]),
		.FpLoadStoreM, .Funct3M(LSUFunct3M), .ReadDataM);
  subwordwrite subwordwrite(.LSUPAdrM(LSUPAdrM[2:0]),
    .LSUFunct3M, .IMAFWriteDataM, .LittleEndianWriteDataM);

  // Compute byte masks
  swbytemaskword #(`LLEN) swbytemask(.Size(LSUFunct3M), .Adr(LSUPAdrM[$clog2(`LLEN/8)-1:0]), .ByteMask(ByteMaskM));

  /////////////////////////////////////////////////////////////////////////////////////////////
  // MW Pipeline Register
  /////////////////////////////////////////////////////////////////////////////////////////////

  flopen #(`LLEN) ReadDataMWReg(clk, ~StallW, ReadDataM, ReadDataW);

  /////////////////////////////////////////////////////////////////////////////////////////////
  // Big Endian Byte Swapper
  //  hart works little-endian internally
  //  swap the bytes when read from big-endian memory
  /////////////////////////////////////////////////////////////////////////////////////////////
  if (`BIGENDIAN_SUPPORTED) begin:endian
    bigendianswap #(`LLEN) storeswap(.BigEndianM, .a(LittleEndianWriteDataM), .y(LSUWriteDataM));
    bigendianswap #(`LLEN) loadswap(.BigEndianM, .a(ReadDataWordM), .y(LittleEndianReadDataWordM));
  end else begin
    assign LSUWriteDataM = LittleEndianWriteDataM;
    assign LittleEndianReadDataWordM = ReadDataWordM;
  end

endmodule
