#include "gateway.h"
#include <string.h>
static int to_fpga(void *ctx,const music_frame *f){music_gateway *g=ctx;return g->send(g->ctx,PORT_FPGA,f);}
void gateway_init(music_gateway *g,music_library *s,uint32_t boot_nonce,void *ctx,int (*send)(void *,unsigned,const music_frame *)){
    memset(g,0,sizeof(*g));g->library=s;g->ctx=ctx;g->send=send;g->boot_nonce=boot_nonce?boot_nonce:1;g->load_session_cursor=g->boot_nonce^0x4d435531u;loader_init(&g->loader,s,g,to_fpga);
}
/* Allocate once per new job, never per retry. Screen/phone callers may keep
 * their own session across multiple songs; each loader starts sequence zero. */
static uint32_t load_session(music_gateway *g,uint32_t caller){
    do{g->load_session_cursor++;}while(!g->load_session_cursor||g->load_session_cursor==caller||
        g->load_session_cursor==g->in_flight.session||g->load_session_cursor==g->extension_session||
        g->load_session_cursor==g->loader.session);
    return g->load_session_cursor;
}
static uint8_t code(int e){switch(e){case 0:return 0;case LIB_BUSY:return 3;case LIB_OFFSET:case LIB_ID:return 4;case LIB_NOT_MOUNTED:return 6;case LIB_NOT_FOUND:return 7;case LIB_FULL:return 8;case LIB_CRC:case LIB_FORMAT:case LIB_RANGE:return 2;default:return 9;}}
static bool safe(music_gateway *g){return !g->pending&&g->status_safe&&g->live_safe&&g->record_safe&&(uint32_t)(g->now-g->status_at)<=2000&&(uint32_t)(g->now-g->live_at)<=2000&&(uint32_t)(g->now-g->record_at)<=2000;}
static void denied(music_gateway *g,const music_frame *p,uint8_t status){music_frame a={0};a.command=p->command|128;a.session=p->session;a.seq=p->seq;a.len=1;a.payload[0]=status;g->send(g->ctx,PORT_PHONE,&a);}
static void title40(uint8_t *out,const char *s){unsigned n=0;while(n<39&&s[n])n++;while(n&&((uint8_t)s[n]&0xc0)==0x80)n--;memset(out,0,40);memcpy(out,s,n);}
static void extension(music_gateway *g,const music_frame *q){
    music_library *s=g->library;music_frame a={0};a.command=q->command|128;a.session=q->session;a.seq=q->seq;a.len=1;
    int retry=wire_retry(&g->extension,q);if(retry){if(retry>0)g->send(g->ctx,PORT_PHONE,&g->extension.response);else denied(g,q,5);return;}
    if(!q->session){denied(g,q,5);return;}
    if(q->session!=g->extension_session){
        if(q->command!=0x70||q->seq||g->owned){denied(g,q,g->owned?3:5);return;}
        g->extension_session=q->session;g->extension_next=0;
    }
    if(q->seq!=g->extension_next){denied(g,q,5);return;}
    int e=0;const uint8_t *p=q->payload;
    bool mutation=q->command>=0x72&&q->command<=0x77;
    if(mutation&&(!g->owned||loader_busy(&g->loader)))e=LIB_BUSY;
    else if(mutation&&q->command!=0x76&&!g->write_allowed)e=LIB_IO;
    else switch(q->command){
    case 0x70:
        if(q->len){e=LIB_RANGE;break;}a.len=20;a.payload[1]=1;a.payload[2]=(s->mounted?1:0)|(g->owned?2:0)|(g->write_allowed?4:0);a.payload[3]=LIB_MAX_SONGS;
        music_put(a.payload+4,FMS_MAX_BYTES,4);a.payload[8]=s->count;music_put(a.payload+9,s->revision,4);music_put(a.payload+13,g->boot_nonce,4);music_put(a.payload+17,g->flash_jedec,3);break;
    case 0x71:{
        if(q->len!=5){e=LIB_RANGE;break;}if(!s->mounted){e=LIB_NOT_MOUNTED;break;}if(music_le32(p)!=s->revision){e=LIB_ID;break;}
        unsigned index=p[4];if(index>=s->count){e=LIB_NOT_FOUND;break;}song_info *v=&s->songs[index];
        a.len=60;music_put(a.payload+1,s->revision,4);a.payload[5]=(uint8_t)index;music_put(a.payload+6,v->id,2);music_put(a.payload+8,v->size,4);music_put(a.payload+12,v->duration,4);music_put(a.payload+16,v->notes,2);title40(a.payload+18,v->title);a.payload[58]=s->count;a.payload[59]=v->id==g->loaded_id&&v->crc==g->loaded_crc;break;
    }
    case 0x72:if(q->len!=14){e=LIB_RANGE;break;}e=library_begin(s,music_le32(p),music_le16(p+4),music_le32(p+6),music_le32(p+10));if(!e){a.len=5;music_put(a.payload+1,0,4);}break;
    case 0x73:if(q->len<9||q->len>60){e=LIB_RANGE;break;}e=library_data(s,music_le32(p),music_le32(p+4),p+8,q->len-8);if(!e){a.len=5;music_put(a.payload+1,s->received,4);}break;
    case 0x74:if(q->len!=4){e=LIB_RANGE;break;}e=library_commit(s,music_le32(p));if(!e){a.len=7;music_put(a.payload+1,s->expected_id,2);music_put(a.payload+3,s->revision,4);}break;
    case 0x75:if(q->len!=4){e=LIB_RANGE;break;}e=library_abort(s,music_le32(p));break;
    case 0x76:
        if(q->len!=10){e=LIB_RANGE;break;}if(music_le32(p+6)!=s->revision){e=LIB_ID;break;}
        e=loader_start(&g->loader,music_le16(p+4),load_session(g,q->session),music_le32(p),g->now);
        if(!e){g->loaded_id=0;g->loader_result_seen=false;a.len=5;music_put(a.payload+1,music_le32(p),4);}break;
    case 0x77:
        if(q->len!=6){e=LIB_RANGE;break;}if(music_le32(p+2)!=s->revision){e=LIB_ID;break;}if(music_le16(p)==g->loaded_id){e=LIB_BUSY;break;}e=library_remove(s,music_le16(p));break;
    case 0x78:
        if(q->len){e=LIB_RANGE;break;}a.len=24;a.payload[1]=g->loader.state;a.payload[2]=code(g->loader.error);a.payload[3]=s->writing;
        music_put(a.payload+4,g->loader.task,4);music_put(a.payload+8,loader_busy(&g->loader)?g->loader.offset:s->received,4);music_put(a.payload+12,loader_busy(&g->loader)?g->loader.song.size:s->expected_size,4);
        music_put(a.payload+16,g->loaded_id,2);music_put(a.payload+18,g->loaded_generation,4);a.payload[22]=g->owned;a.payload[23]=s->count;break;
    case 0x79:
        if(q->len){e=LIB_RANGE;break;}if(s->writing||loader_busy(&g->loader)){e=LIB_BUSY;break;}g->owned=false;g->status_safe=g->live_safe=g->record_safe=false;break;
    case 0x7a:
        if(q->len!=4||memcmp(p,"LIB1",4)){e=LIB_RANGE;break;}
        if(g->owned){e=LIB_BUSY;break;}if(!safe(g)){e=LIB_BUSY;break;}g->owned=true;g->last_owner_at=g->now;break;
    case 0x7b:{
        if(q->len!=6){e=LIB_RANGE;break;}if(music_le32(p+2)!=s->revision){e=LIB_ID;break;}
        unsigned i;for(i=0;i<s->count;i++)if(s->songs[i].id==music_le16(p))break;
        if(i==s->count){e=LIB_NOT_FOUND;break;}a.len=55;music_put(a.payload+1,s->songs[i].id,2);music_put(a.payload+3,s->songs[i].crc,4);memcpy(a.payload+7,s->songs[i].title,48);break;
    }
    case 0x7f:
        if(q->len!=8||memcmp(p,"INITLFS!",8)){e=LIB_RANGE;break;}if(!g->owned||s->mounted||loader_busy(&g->loader)){e=LIB_BUSY;break;}
        if(!g->write_allowed){e=LIB_IO;break;}e=library_format(s);if(!e)e=library_mount(s);break;
    default:e=LIB_RANGE;break;
    }
    a.payload[0]=code(e);if(e)a.len=1;g->extension_next++;g->last_owner_at=g->now;wire_remember(&g->extension,q,&a);g->send(g->ctx,PORT_PHONE,&a);
}
void gateway_phone(music_gateway *g,const music_frame *p,uint32_t now){
    g->now=now;g->connected=true;
    if(p->command>=0x70&&p->command<=0x7f){extension(g,p);return;}
    if(g->owned||loader_busy(&g->loader)){denied(g,p,3);return;}
    /* One request outstanding. A new CAPS explicitly rebuilds a phone session. */
    if(g->pending&&(p->command!=g->in_flight.command||p->session!=g->in_flight.session||p->seq!=g->in_flight.seq)&&p->command!=0x50){denied(g,p,3);return;}
    if(p->command!=0x50&&p->command!=0x51&&p->command!=0x64&&p->command!=0x68)g->status_safe=g->live_safe=g->record_safe=false;
    if(p->command==0x58){g->loaded_id=0;g->loaded_crc=0;g->phone_upload_crc=p->len==12?music_le32(p->payload+8):0;}
    g->in_flight=*p;g->pending=true;
    if(g->send(g->ctx,PORT_FPGA,p)){g->pending=false;denied(g,p,9);}
}
void gateway_fpga(music_gateway *g,const music_frame *p,uint32_t now){
    g->now=now;
    if(p->command>=0x40&&p->command<=0x43){gateway_screen(g,p,now);return;}
    if(loader_accept(&g->loader,p,now))return;
    if(!g->pending||p->session!=g->in_flight.session||p->seq!=g->in_flight.seq||p->command!=(g->in_flight.command|128))return;
    g->pending=false;
    if(p->len&&p->payload[0]==0){
        if(p->command==0xd1&&p->len==53){g->status_safe=!(p->payload[2]&0x72);g->status_at=now;uint16_t id=(p->payload[2]&1)?music_le16(p->payload+10):0;uint32_t gen=music_le32(p->payload+12);if(id!=g->loaded_id||gen!=g->loaded_generation)g->loaded_crc=0;g->loaded_id=id;g->loaded_generation=gen;}
        if(p->command==0xda&&p->len==7){g->loaded_id=music_le16(p->payload+1);g->loaded_generation=music_le32(p->payload+3);g->loaded_crc=g->phone_upload_crc;}
        if(p->command==0xe8&&p->len==13){g->live_safe=p->payload[6]==0;g->live_at=now;}
        if(p->command==0xe4&&p->len==18){g->record_safe=(p->payload[5]&3)==0;g->record_at=now;}
    }
    g->send(g->ctx,PORT_PHONE,p);
}
void gateway_poll(music_gateway *g,uint32_t now){
    g->now=now;loader_poll(&g->loader,now);
    if(g->loader.state==LOAD_DONE&&!g->loader_result_seen){g->loaded_id=g->loader.song.id;g->loaded_generation=g->loader.generation;g->loaded_crc=g->loader.song.crc;g->loader_result_seen=true;}
    if(g->screen_owned&&!loader_busy(&g->loader)){g->owned=false;g->screen_owned=false;}
    if(g->owned&&!loader_busy(&g->loader)&&(uint32_t)(now-g->last_owner_at)>15000){
        if(g->library->writing)(void)library_abort(g->library,g->library->task);
        g->owned=false;g->extension_session=0;g->extension.valid=false;g->status_safe=g->live_safe=g->record_safe=false;
    }
}
void gateway_disconnected(music_gateway *g){
    g->connected=false;g->pending=false;g->status_safe=g->live_safe=g->record_safe=false;
    if(!loader_busy(&g->loader)){if(g->library->writing)(void)library_abort(g->library,g->library->task);g->owned=false;g->extension_session=0;g->extension.valid=false;}
}
void gateway_screen(music_gateway *g,const music_frame *q,uint32_t now){
    g->now=now;music_library *s=g->library;music_frame a={0};a.command=q->command|128;a.session=q->session;a.seq=q->seq;a.len=1;int e=0;
    if(!q->session)e=LIB_ID;
    else if(q->command==0x40){
        if(q->len!=0&&q->len!=7)e=LIB_RANGE;
        else if(q->len==7&&(q->payload[0]&~1u))e=LIB_RANGE;
        else{
            /* The FPGA supplies its current RAM identity, including reset state.
             * Without it, a historic MCU observation must not mean "loaded". */
            if(q->len!=7||!q->payload[0]||music_le16(q->payload+1)!=g->loaded_id||music_le32(q->payload+3)!=g->loaded_generation){g->loaded_id=0;g->loaded_crc=0;g->loaded_generation=0;}
            a.len=10;a.payload[1]=1;a.payload[2]=s->count;a.payload[3]=(s->mounted?1:0)|(g->connected?2:0)|(g->owned?4:0);music_put(a.payload+4,s->revision,4);a.payload[8]=48;a.payload[9]=72;
        }
    }else if(q->command==0x41){
        if(q->len!=5)e=LIB_RANGE;else if(!s->mounted)e=LIB_NOT_MOUNTED;else if(music_le32(q->payload)!=s->revision)e=LIB_ID;
        else if(q->payload[4]>=s->count)e=LIB_NOT_FOUND;
        else{unsigned index=q->payload[4];song_info *v=&s->songs[index];a.len=60;music_put(a.payload+1,s->revision,4);a.payload[5]=(uint8_t)index;music_put(a.payload+6,v->id,2);music_put(a.payload+8,v->size,4);music_put(a.payload+12,v->duration,4);music_put(a.payload+16,v->notes,2);title40(a.payload+18,v->title);a.payload[58]=s->count;a.payload[59]=v->id==g->loaded_id&&v->crc==g->loaded_crc;}
    }else if(q->command==0x42){
        int retry=wire_retry(&g->screen_load,q);if(retry){if(retry>0)g->send(g->ctx,PORT_FPGA,&g->screen_load.response);else{a.payload[0]=5;g->send(g->ctx,PORT_FPGA,&a);}return;}
        if(q->len!=10)e=LIB_RANGE;else if(g->connected||g->pending||g->owned||s->writing)e=LIB_BUSY;
        else if(music_le32(q->payload+6)!=s->revision)e=LIB_ID;
        else{
            uint32_t session=load_session(g,q->session);
            g->owned=g->screen_owned=true;g->last_owner_at=now;
            e=loader_start(&g->loader,music_le16(q->payload+4),session,music_le32(q->payload),now);
            if(e)g->owned=g->screen_owned=false;else{g->loaded_id=0;g->loader_result_seen=false;a.len=5;music_put(a.payload+1,music_le32(q->payload),4);}
        }
    }else if(q->command==0x43){
        if(q->len)e=LIB_RANGE;else{a.len=24;a.payload[1]=g->loader.state;a.payload[2]=code(g->loader.error);a.payload[3]=s->writing;music_put(a.payload+4,g->loader.task,4);music_put(a.payload+8,g->loader.offset,4);music_put(a.payload+12,g->loader.song.size,4);music_put(a.payload+16,g->loaded_id,2);music_put(a.payload+18,g->loaded_generation,4);a.payload[22]=g->owned;a.payload[23]=s->count;}
    }else e=LIB_RANGE;
    a.payload[0]=code(e);if(e)a.len=1;
    if(q->command==0x42)wire_remember(&g->screen_load,q,&a);
    g->send(g->ctx,PORT_FPGA,&a);
}
