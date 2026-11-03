"""Generate the complete current dictionary from the reviewed flat text asset."""
from pathlib import Path
import hashlib,json,argparse
P=Path(__file__).resolve().parents[1]

def generate():
 rows=json.loads((P/'assets/ui_text.json').read_text(encoding='utf8'))['rows']
 assert len(rows)==1024 and all(len(x)==64 for x in rows)
 assert all(0<=ord(c)<128 for x in rows for c in x)
 chunks=[];ci={};lines=[];li={};lm=[]
 for text in rows:
  line=[]
  for k in range(0,64,8):
   ch=tuple(map(ord,text[k:k+8]))
   if ch not in ci:ci[ch]=len(chunks);chunks.append(ch)
   line.append(ci[ch])
  key=tuple(line)
  if key not in li:li[key]=len(lines);lines.append(key)
  lm.append(li[key])
 assert len(lines)<=512 and len(chunks)<=768,(len(lines),len(chunks))
 values={'lines':lm,'chunks0':[0]*2048,'chunks1':[0]*2048,'bank0':[32]*2048,'bank1':[32]*2048,'bank2':[32]*2048,'masks':[0]*512}
 high=[]
 for i,line in enumerate(lines):
  for j,c in enumerate(line):
   a=i*8+j;values['chunks'+str(a>>11)][a&2047]=c&511
   if c&512:high.append(a);values['masks'][i]|=1<<j
 for i,ch in enumerate(chunks):
  for j,c in enumerate(ch):a=i*8+j;values['bank'+str(a>>11)][a&2047]=c
 values['lines']=[(values['masks'][line_id]<<9)|line_id for line_id in lm]
 del values['masks']
 s='''// Generated from assets/ui_text.json. Four-clock dictionary interface.
module ui_labels(input wire clk,input wire[15:0]address,output reg[8:0]character);
(* syn_ramstyle="block_ram" *)reg[17:0]lines[0:1023];
(* syn_ramstyle="block_ram" *)reg[8:0]chunks0[0:2047],chunks1[0:2047];
(* syn_ramstyle="block_ram" *)reg[6:0]bank0[0:2047],bank1[0:2047],bank2[0:2047];
reg[17:0]line_word_q;wire[8:0]line_q=line_word_q[8:0];reg[8:0]chunk0_q,chunk1_q;reg[5:0]column_q;reg[2:0]a;
reg chunk_bank;reg[7:0]mask_q;reg[2:0]mask_bit_q;
wire chunk_high=mask_q[mask_bit_q];reg[1:0]bank_select;reg[6:0]q0,q1,q2;
wire[11:0]chunk_address={line_q,column_q[5:3]};
wire[9:0]chunk={chunk_high,chunk_bank ? chunk1_q : chunk0_q};wire[12:0]pa={chunk,a};
initial begin
'''
 for name,v in values.items():
  width=18 if name=='lines'else 9 if name.startswith('chunks') else 7
  s+=''.join(f"{name}[{i}]={width}'d{x};\n" for i,x in enumerate(v))
 s+='''end
always @(posedge clk)begin
 line_word_q<=lines[address[15:6]];column_q<=address[5:0];a<=column_q[2:0];
 chunk0_q<=chunks0[chunk_address[10:0]];chunk1_q<=chunks1[chunk_address[10:0]];
 chunk_bank<=chunk_address[11];mask_q<=line_word_q[16:9];mask_bit_q<=column_q[5:3];
 bank_select<=pa[12:11];q0<=bank0[pa[10:0]];q1<=bank1[pa[10:0]];q2<=bank2[pa[10:0]];
 case(bank_select)0:character<={2'd0,q0};1:character<={2'd0,q1};2:character<={2'd0,q2};default:character<=9'd32;endcase
end
endmodule
'''
 return s,rows,dict(lines=len(lines),chunks=len(chunks),high_entries=len(high),mask_packed_in_line_word=True,line_ROM_width=18,removed_mapped_RAM_hypothesis=1,interface_clocks=4)

if __name__=='__main__':
 ap=argparse.ArgumentParser();ap.add_argument('--check',action='store_true');a=ap.parse_args()
 text,rows,info=generate();dest=P/'src/ui_labels.v'
 if a.check:assert dest.read_text()==text,'Dictionary asset and generated RTL differ'
 else:dest.write_text(text)
 print('Dictionary ready',info)
