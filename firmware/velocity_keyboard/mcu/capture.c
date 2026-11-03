#include "capture.h"
static unsigned used(const dc_capture*c){return (c->head-c->tail)&(DC_QUEUE-1u);}
static void push(dc_capture*c,dc_record r){c->q[c->head]=r;c->head=(c->head+1u)&(DC_QUEUE-1u);}
static void fault(dc_capture*c,uint8_t flag){
 c->fault_flags|=flag;c->needs_rebase=1;
 if(flag==DC_OVERFLOW)c->overflows++;else c->timing_faults++;
}
void dc_init(dc_capture*c,uint32_t session){
 unsigned i;volatile uint8_t*p=(volatile uint8_t*)c;
 for(i=0;i<sizeof(*c);i++)p[i]=0;
 c->session=session;c->needs_rebase=1;
}
void dc_sample(dc_capture*c,uint8_t row,uint8_t closed,uint32_t time){
 dc_record r;uint32_t gap;unsigned i;
 if(row>3)return;
 if(c->started){
  gap=time-c->last_time;if(gap>c->max_gap)c->max_gap=gap;
  if(gap>75u)fault(c,DC_TIMING);
 }
 c->last_time=time;c->started=1;c->samples++;
 r.time=time;r.row=row;r.bits=closed;r.kind=0;r.pad=0;
 if((!(c->valid&(1u<<row))||c->latest[row].bits!=closed)&&!c->needs_rebase){
  if(used(c)>=DC_QUEUE-1u)fault(c,DC_OVERFLOW);else push(c,r);
 }
 c->latest[row]=r;c->valid|=(uint8_t)(1u<<row);
 if(row==3 && ++c->snapshot_div==20){
  c->snapshot_div=0;
  if(!c->needs_rebase){
   if(used(c)>DC_QUEUE-5u)fault(c,DC_OVERFLOW);
   else for(i=0;i<4;i++){r=c->latest[i];r.kind=(uint8_t)(i==0?1:2);push(c,r);}
  }
 }
}
int dc_take(dc_capture*c,dc_batch*b){
 unsigned i;
 if(c->valid!=15)return 0;
 b->flags=0;
 if(c->needs_rebase){
  c->tail=c->head;c->session++;b->type=1;b->count=4;
  b->flags=(uint8_t)(DC_REBASE|c->fault_flags);c->fault_flags=0;c->needs_rebase=0;
  for(i=0;i<4;i++)b->records[i]=c->latest[i];
 }else if(c->tail!=c->head){
  b->type=c->q[c->tail].kind==1?1:2;b->count=0;
  do{
   b->records[b->count++]=c->q[c->tail];c->tail=(c->tail+1u)&(DC_QUEUE-1u);
   if(c->tail==c->head)break;
  }while(b->count<(b->type==1?4:8) && (b->type==1||c->q[c->tail].kind==0));
 }else return 0;
 b->session=c->session;b->seq=c->seq++;
 return 1;
}
uint16_t dc_crc(const uint8_t*d,unsigned n){
 uint16_t crc=0xffff;unsigned i;
 while(n--){crc^=(uint16_t)(*d++)<<8;for(i=0;i<8;i++)crc=(uint16_t)((crc<<1)^((crc&0x8000)?0x1021:0));}
 return crc;
}
static void le32(uint8_t*p,uint32_t v){unsigned i;for(i=0;i<4;i++)p[i]=(uint8_t)(v>>(8*i));}
unsigned dc_encode(const dc_batch*b,uint8_t*out){
 uint8_t raw[64];unsigned i,n=9,k=0;uint16_t crc;
 raw[0]=1;raw[1]=b->type;raw[2]=(uint8_t)(2+6*b->count+(b->type==1?6:0));
 le32(raw+3,b->session);raw[7]=(uint8_t)b->seq;raw[8]=(uint8_t)(b->seq>>8);
 raw[n++]=b->flags;raw[n++]=b->count;
 for(i=0;i<b->count;i++){
  raw[n++]=b->records[i].row;raw[n++]=b->records[i].bits;le32(raw+n,b->records[i].time);n+=4;
 }
 if(b->type==1){raw[n++]=1;raw[n++]=0;raw[n++]=25;raw[n++]=0;raw[n++]=100;raw[n++]=0;}
 crc=dc_crc(raw,n);raw[n++]=(uint8_t)(crc>>8);raw[n++]=(uint8_t)crc;
 out[k++]=0x7e;
 for(i=0;i<n;i++){if(raw[i]==0x7e||raw[i]==0x7d){out[k++]=0x7d;out[k++]=raw[i]^0x20;}else out[k++]=raw[i];}
 out[k++]=0x7e;return k;
}
uint32_t dc_timer_read_result(uint32_t high,uint16_t first,uint8_t overflow,uint16_t second){
 return overflow?high+0x10000u+second:high+first;
}
