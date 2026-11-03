#include "wire.h"
#include "library.h"
#include <string.h>
uint16_t wire_crc16(const uint8_t *p,size_t n){uint16_t c=65535;while(n--){c^=(uint16_t)*p++<<8;for(unsigned i=0;i<8;i++)c=(uint16_t)((c<<1)^((c&32768)?0x1021:0));}return c;}
size_t wire_encode(const music_frame *f,uint8_t out[154]){
    if(f->len>64)return 0;uint8_t b[76]={1,f->command};music_put(b+2,f->session,4);music_put(b+6,f->seq,2);music_put(b+8,f->len,2);memcpy(b+10,f->payload,f->len);
    size_t n=12+f->len;music_put(b+n-2,wire_crc16(b,n-2),2);size_t j=0;out[j++]=126;
    for(size_t i=0;i<n;i++){if(b[i]==125||b[i]==126){out[j++]=125;out[j++]=b[i]^32;}else out[j++]=b[i];}out[j++]=126;return j;
}
bool wire_feed(wire_decoder *d,uint8_t x,uint32_t now,music_frame *out){
    if(d->active&&d->n&&(uint32_t)(now-d->last_ms)>100){d->active=d->escape=d->discard=false;d->n=0;d->timeouts++;}d->last_ms=now;
    if(x==126){
        bool valid=false;
        if(d->active&&(d->n||d->escape||d->discard)){
            unsigned n=d->n;
            if(!d->escape&&!d->discard&&n>=12&&d->raw[0]==1&&music_le16(d->raw+8)<=64&&n==12u+music_le16(d->raw+8)&&wire_crc16(d->raw,n-2)==music_le16(d->raw+n-2)){
                out->command=d->raw[1];out->session=music_le32(d->raw+2);out->seq=music_le16(d->raw+6);out->len=(uint8_t)(n-12);memcpy(out->payload,d->raw+10,out->len);valid=true;
            }else d->malformed++;
        }
        d->active=true;d->escape=d->discard=false;d->n=0;return valid;
    }
    if(!d->active||d->discard)return false;
    if(d->escape){d->escape=false;if(x!=93&&x!=94){d->discard=true;return false;}x^=32;}
    else if(x==125){d->escape=true;return false;}
    if(d->n>=76)d->discard=true;else d->raw[d->n++]=x;return false;
}
int wire_retry(const wire_replay *r,const music_frame *f){
    if(!r->valid||r->request.session!=f->session||r->request.seq!=f->seq)return 0;
    return r->request.command==f->command&&r->request.len==f->len&&!memcmp(r->request.payload,f->payload,f->len)?1:-1;
}
void wire_remember(wire_replay *r,const music_frame *q,const music_frame *a){r->valid=true;r->request=*q;r->response=*a;}
