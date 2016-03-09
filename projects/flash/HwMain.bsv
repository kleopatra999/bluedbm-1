import FIFO::*;
import FIFOF::*;
import Clocks::*;
import Vector::*;

import BRAM::*;
import BRAMFIFO::*;

import MergeN::*;

import PcieCtrl::*;

import DMASplitter::*;

import AuroraImportFmc1::*;
import ControllerTypes::*;
import FlashCtrlVirtex1::*;
import FlashCtrlModel::*;
import DualFlashManager::*;

typedef 8 BusCount; // 8 per card in hw, 2 per card in sim
typedef TMul#(2,BusCount) BBusCount; //Board*bus
//typedef 64 TagCount; // Has to be larger than the software setting

interface HwMainIfc;
endinterface

module mkHwMain#(PcieUserIfc pcie, Vector#(2,FlashCtrlUser) flashes, FlashManagerIfc flashMan) 
	(HwMainIfc);

	Clock curClk <- exposeCurrentClock;
	Reset curRst <- exposeCurrentReset;

	Clock pcieclk = pcie.user_clk;
	Reset pcierst = pcie.user_rst;

	Integer busCount = valueOf(BusCount);
	//Integer tagCount = valueOf(TagCount);

	DMASplitterIfc#(4) dma <- mkDMASplitter(pcie);

	Merge2Ifc#(Bit#(128)) m0 <- mkMerge2;
	Merge2Ifc#(Bit#(32)) m4flash <- mkMerge2;

	FIFO#(FlashCmd) flashCmdQ <- mkFIFO;
	Vector#(8, Reg#(Bit#(32))) writeBuf <- replicateM(mkReg(0));

	DualFlashManagerIfc flashman <- mkDualFlashManager(flashes);
	
	// 8'available 8'type 16'data
	// type: 0: readdone, 1: writedone 2: erasedone 3:erasefail 4: writeready
	FIFOF#(Bit#(32)) flashStatusQ <- mkFIFOF(clocked_by pcieclk, reset_by pcierst);
	Reg#(Bit#(8)) flashStatusOut <- mkReg(0);
	FIFO#(Bit#(8)) writeTagsQ <- mkSizedBRAMFIFO(128);

	Reg#(Bit#(16)) flashWriteBytes <- mkReg(0);
	Reg#(Maybe#(Bit#(64))) flashWriteBuf <- mkReg(tagged Invalid);

	//Vector#(TagCount,Reg#(Bit#(5))) tagBusMap <- replicateM(mkReg(0));
	Reg#(Bool) started <- mkReg(False);

	rule senddmaenq;
		m0.deq;
		dma.enq(0, m0.first);
	endrule
	/*
	rule flushm4flash;
		m4flash.deq;
		m0.enq[0].enq(zeroExtend(m4flash.first));
	endrule
	*/

	FIFO#(Bit#(128)) dmainQ <- mkFIFO;
	rule getFlashCmd;
		dma.deq;
		started <= True;
		Bit#(128) d = dma.first;
		dmainQ.enq(d);
	endrule

	FIFO#(Tuple2#(Bit#(128), Bit#(8))) flashWriteQ <- mkFIFO;
	Reg#(Bit#(32)) flashWriteBytesOut <- mkReg(0);
	Reg#(Bit#(8)) flashWriteTag <- mkReg(0);
	rule flashWriteR;
		if ( flashWriteBytesOut + 16 <= 8192 ) begin
			let d = flashWriteQ.first;
			flashWriteQ.deq;
			let data = tpl_1(d);
			let tag = tpl_2(d);
			flashWriteTag <= tag;
			let board = tag[6];

			flashman.ifc[board].writeWord(tag, data);
			flashWriteBytesOut <= flashWriteBytesOut + 16;
		end else begin
			let board = flashWriteTag[6];
			flashman.ifc[board].writeWord(flashWriteTag, 0);
			if ( flashWriteBytesOut + 16 >= 8192+32 ) begin
				flashWriteBytesOut <= 0;
			end else begin
				flashWriteBytesOut <= flashWriteBytesOut + 16;
			end
		end
	endrule
	
	rule procFlashCmd;
		let d = dmainQ.first;
		dmainQ.deq;

		let conf = d[127:96];
		if ( conf == 0 ) begin
			let opcode = d[31:0];

			let cur_blockpagechip = d[63:32];
			let cur_bustag = d[95:64];
			Bit#(1) board = cur_bustag[6];
			Bit#(3) bus = truncate(cur_bustag>>3);
			Bit#(4) bbus = truncate(cur_bustag>>3);
			Bit#(8) tag = truncate(cur_bustag);

			let cur_flashop = ERASE_BLOCK;
			if ( opcode == 0 ) cur_flashop = ERASE_BLOCK;
			else if ( opcode == 1 ) begin
				cur_flashop = READ_PAGE;
			end
			else if ( opcode == 2 ) begin
				cur_flashop = WRITE_PAGE;
			end

			if ( opcode <= 2 ) begin
				//$display( "cmd recv %d", opcode );	
				flashman.command(FlashManagerCmd{
					op:cur_flashop,
					tag:truncate(tag),
					bus: truncate(bbus),
					chip: truncate(cur_blockpagechip),
					block:truncate(cur_blockpagechip>>16),
					page:truncate(cur_blockpagechip>>8)
					});
			end
		end else if ( conf == 1 ) begin
			Bit#(64) data = truncate(d);
			if ( isValid(flashWriteBuf) ) begin
				let d2 = fromMaybe(?, flashWriteBuf);
				flashWriteQ.enq(tuple2({data, d2}, truncate(writeTagsQ.first)));
				if ( flashWriteBytes + 16 >= 8192 ) begin
					writeTagsQ.deq;
					flashWriteBytes <= 0;
				end else begin
					flashWriteBytes <= flashWriteBytes + 16;
				end

				flashWriteBuf <= tagged Invalid;
			end else begin
				flashWriteBuf <= tagged Valid data;
			end
		end
	endrule


	rule flashEvent;
		let evt <- flashman.fevent;
		Bit#(8) tag = tpl_1(evt);
		FlashStatus stat = tpl_2(evt);
		Bit#(32) data = 0;
		case (stat)
			STATE_WRITE_DONE: data = {8'h00, 8'h1, zeroExtend(tag)};
			STATE_ERASE_DONE: data = {8'h00, 8'h2, zeroExtend(tag)};
			STATE_ERASE_FAIL: data = {8'h00, 8'h3, zeroExtend(tag)};
			STATE_WRITE_READY: data = {8'h00, 8'h4, zeroExtend(tag)};
		endcase
		m0.enq[0].enq(zeroExtend(data));

		if ( stat == STATE_WRITE_READY ) begin
			writeTagsQ.enq(tag);
		end
	endrule

	Merge4Ifc#(Bit#(8)) m4dma <- mkMerge4;
	rule sendReadDone;
		m4dma.deq;
		Bit#(8) tag = m4dma.first;
		Bit#(32) data = {8'h0, 8'h0, zeroExtend(tag)}; // read done
		//dma.enq({zeroExtend(data)}); 
		m0.enq[1].enq(zeroExtend(data));
		//$display( "dma.enq from %d", tag );
	endrule

	for ( Integer i = 0; i < 2; i=i+1 ) begin
		Vector#(BusCount, FIFO#(Tuple2#(Bit#(128), Bit#(8)))) dmaWriteQ <- replicateM(mkSizedFIFO(32));
		Vector#(BusCount, Reg#(Bit#(16))) dmaWriteCnt <- replicateM(mkReg(0));
		FIFO#(Tuple2#(Bit#(8), Bit#(128))) flashReadQ <- mkSizedFIFO(16);
		rule readDataFromFlash1;
			let taggedRdata <- flashman.ifc[i].readWord();
			flashReadQ.enq(taggedRdata);
		endrule

		//Tag, Count
		Vector#(TDiv#(BusCount,4), Merge4Ifc#(Tuple2#(Bit#(8),Bit#(10)))) dmaEngineSelect <- replicateM(mkMerge4);

		rule relayDMAWrite;
			flashReadQ.deq;
			let d = flashReadQ.first;

			let tag = tpl_1(d);
			let data = tpl_2(d);
			Bit#(3) busid = tag[5:3];
			
			let curcnt = dmaWriteCnt[busid];
			if ( curcnt < 8192/16 ) begin
				dmaWriteQ[busid].enq(tuple2(data,tag));
				dmaWriteCnt[busid] <= curcnt+1;

				if ( curcnt[2:0] == 3'b111 ) begin
					Tuple2#(Bit#(8),Bit#(10)) dmaReq;
					let mergeidx = busid[1:0];

					dmaReq = tuple2(tag, 8);
					dmaEngineSelect[busid>>2].enq[mergeidx].enq(dmaReq);
				end
			end else if ( curcnt < (8192+32)/16 -1 ) begin
				dmaWriteCnt[busid] <= curcnt+1;
			end else if ( curcnt >= (8192+32)/16 -1 ) begin
				dmaWriteCnt[busid] <= 0;
			end
		endrule

		// Per PCIe writeEngine
		for ( Integer j = 0; j < busCount/4; j = j + 1 ) begin
			Vector#(4, Reg#(Bit#(16))) dmaOffset <- replicateM(mkReg(0));
			Reg#(Bit#(5)) dmaSrcBus <- mkReg(0);
			Reg#(Bit#(5)) dmaEWriteCnt <- mkReg(0);

			rule startdmawrite(dmaEWriteCnt == 0);
				Bit#(2) dui = fromInteger(i)*2+fromInteger(j);
				dmaEngineSelect[j].deq;
				let d = dmaEngineSelect[j].first;

				let tag = tpl_1(d);
				let dmacnt = tpl_2(d);
				Bit#(3) busid = tag[5:3];
				let mergeidx = busid[1:0];

				dmaSrcBus <= zeroExtend(mergeidx);
				dmaEWriteCnt <= truncate(dmacnt);

				dma.users[dui].dmaWriteReq((zeroExtend(tag)<<13) | zeroExtend(dmaOffset[mergeidx]), dmacnt, tag);

				if ( dmaOffset[mergeidx] + 128 >= 8192) begin
					m4dma.enq[dui].enq(tag);
					dmaOffset[mergeidx] <= 0;
				end else begin
					dmaOffset[mergeidx] <= dmaOffset[mergeidx] + 128;
				end

			endrule

			rule sendDmaData(dmaEWriteCnt > 0);
				if ( dmaSrcBus == 0 ) begin
					Bit#(3) idx = fromInteger(j)*4;
					Bit#(2) dui = fromInteger(i)*2+fromInteger(j);
					
					dmaWriteQ[idx].deq;
					let data = dmaWriteQ[idx].first;
					dma.users[dui].dmaWriteData(tpl_1(data), tpl_2(data));
				end else 
				if ( dmaSrcBus == 1 ) begin
					Bit#(3) idx = fromInteger(j)*4 + 1;
					Bit#(2) dui = fromInteger(i)*2+fromInteger(j);

					dmaWriteQ[idx].deq;
					let data = dmaWriteQ[idx].first;
					dma.users[dui].dmaWriteData(tpl_1(data), tpl_2(data));
				end else 
				if ( dmaSrcBus == 2 ) begin
					Bit#(3) idx = fromInteger(j)*4 + 2;
					Bit#(2) dui = fromInteger(i)*2+fromInteger(j);

					dmaWriteQ[idx].deq;
					let data = dmaWriteQ[idx].first;
					dma.users[dui].dmaWriteData(tpl_1(data), tpl_2(data));
				end else 
				if ( dmaSrcBus == 3 ) begin
					Bit#(3) idx = fromInteger(j)*4 + 3;
					Bit#(2) dui = fromInteger(i)*2+fromInteger(j);

					dmaWriteQ[idx].deq;
					let data = dmaWriteQ[idx].first;
					dma.users[dui].dmaWriteData(tpl_1(data), tpl_2(data));
				end 
				dmaEWriteCnt <= dmaEWriteCnt - 1;
			endrule
		end
	end



endmodule
