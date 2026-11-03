#include "loader.h"
#include <string.h>
static void finish(music_loader *l,unsigned state,int error){
    l->waiting=false;if(l->opened){if(lfs_file_close(&l->library->fs,&l->file)&&!error)error=LIB_IO;l->opened=false;}
    l->state=(uint8_t)state;l->error=error;
}
bool loader_busy(const music_loader *l){return l->state>=LOAD_CAPS&&l->state<=LOAD_VERIFY;}
void loader_init(music_loader *l,music_library *s,void *ctx,int (*send)(void *,const music_frame *)){
    memset(l,0,sizeof(*l));l->library=s;l->ctx=ctx;l->send=send;l->cfg.buffer=l->cache;
}
static int read_song(void *ctx,uint32_t a,void *p,uint32_t n){music_loader *l=ctx;return lfs_file_seek(&l->library->fs,&l->file,(lfs_soff_t)a,LFS_SEEK_SET)!=(lfs_soff_t)a||lfs_file_read(&l->library->fs,&l->file,p,n)!=(lfs_ssize_t)n?-1:0;}
int loader_start(music_loader *l,uint16_t id,uint32_t session,uint32_t task,uint32_t now){
    if(loader_busy(l)||l->library->writing)return LIB_BUSY;if(!session||!task)return LIB_RANGE;
    int e=library_open(l->library,id,&l->file,&l->cfg);if(e)return e;l->opened=true;
    lfs_soff_t size=lfs_file_size(&l->library->fs,&l->file);
    e=size<0?LIB_IO:fms_validate(read_song,l,(uint32_t)size,&l->song);
    if(e||l->song.id!=id){finish(l,LOAD_FAILED,e?e:LIB_ID);return l->error;}
    l->session=session;l->task=task;l->seq=0;l->offset=0;l->waiting=false;l->state=LOAD_CAPS;l->error=0;l->generation=0;
    loader_poll(l,now);return loader_busy(l)?0:l->error;
}
void loader_poll(music_loader *l,uint32_t now){
    if(!loader_busy(l))return;
    if(l->waiting){
        if((int32_t)(now-l->deadline)<0)return;
        if(l->retries>=2){finish(l,l->state==LOAD_COMMIT||l->state==LOAD_VERIFY?LOAD_UNKNOWN:LOAD_FAILED,LIB_IO);return;}
        l->retries++;l->deadline=now+2500;
        if(l->send(l->ctx,&l->pending))finish(l,l->state==LOAD_COMMIT?LOAD_UNKNOWN:LOAD_FAILED,LIB_IO);return;
    }
    music_frame *p=&l->pending;memset(p,0,sizeof(*p));p->session=l->session;p->seq=l->seq;
    switch(l->state){
    case LOAD_CAPS:p->command=0x50;break;
    case LOAD_STATUS:case LOAD_VERIFY:p->command=0x51;break;
    case LOAD_LIVE:p->command=0x68;break;
    case LOAD_RECORD:p->command=0x64;break;
    case LOAD_BEGIN:p->command=0x58;p->len=12;music_put(p->payload,l->task,4);music_put(p->payload+4,l->song.size,4);music_put(p->payload+8,l->song.crc,4);break;
    case LOAD_DATA:{
        p->command=0x59;uint32_t n=l->song.size-l->offset;if(n>52)n=52;p->len=(uint8_t)(8+n);
        music_put(p->payload,l->task,4);music_put(p->payload+4,l->offset,4);
        if(read_song(l,l->offset,p->payload+8,n)){finish(l,LOAD_FAILED,LIB_IO);return;}break;
    }
    case LOAD_COMMIT:p->command=0x5a;p->len=4;music_put(p->payload,l->task,4);break;
    default:finish(l,LOAD_FAILED,LIB_FORMAT);return;
    }
    l->waiting=true;l->retries=0;l->deadline=now+2500;
    if(l->send(l->ctx,p))finish(l,l->state==LOAD_COMMIT?LOAD_UNKNOWN:LOAD_FAILED,LIB_IO);
}
bool loader_accept(music_loader *l,const music_frame *p,uint32_t now){
    if(!loader_busy(l)||!l->waiting||p->session!=l->session||p->seq!=l->seq||p->command!=(l->pending.command|128))return false;
    l->waiting=false;
    if(!p->len){finish(l,l->state==LOAD_COMMIT?LOAD_UNKNOWN:LOAD_FAILED,LIB_FORMAT);return true;}
    if(p->payload[0]){finish(l,LOAD_FAILED,p->payload[0]==3?LIB_BUSY:LIB_FORMAT);return true;}
    bool valid=true;uint8_t next=l->state+1;
    switch(l->state){
    case LOAD_CAPS:valid=p->len==18&&p->payload[1]==8&&p->payload[2]==48&&p->payload[3]==72&&(p->payload[4]&2)&&music_le16(p->payload+5)>=l->song.events&&music_le16(p->payload+7)>=l->song.notes&&music_le32(p->payload+9)>=l->song.size&&p->payload[16]==16&&p->payload[17]==4;break;
    case LOAD_STATUS:valid=p->len==53&&p->payload[1]==8;if(valid&&(p->payload[2]&0x72)){finish(l,LOAD_FAILED,LIB_BUSY);return true;}break;
    case LOAD_LIVE:valid=p->len==13&&p->payload[1]==1&&p->payload[2]==25&&p->payload[3]==4;if(valid&&p->payload[6]){finish(l,LOAD_FAILED,LIB_BUSY);return true;}break;
    case LOAD_RECORD:valid=p->len==18;if(valid&&(p->payload[5]&3)){finish(l,LOAD_FAILED,LIB_BUSY);return true;}break;
    case LOAD_BEGIN:valid=p->len==5&&music_le32(p->payload+1)==0;break;
    case LOAD_DATA:valid=p->len==5&&music_le32(p->payload+1)==l->offset+l->pending.len-8;
        if(valid){l->offset+=l->pending.len-8;next=l->offset==l->song.size?LOAD_COMMIT:LOAD_DATA;}break;
    case LOAD_COMMIT:valid=p->len==7&&music_le16(p->payload+1)==l->song.id;if(valid)l->generation=music_le32(p->payload+3);break;
    case LOAD_VERIFY:valid=p->len==53&&p->payload[1]==8&&(p->payload[2]&1)&&!(p->payload[2]&0x70)&&music_le16(p->payload+10)==l->song.id&&music_le32(p->payload+12)==l->generation&&music_le32(p->payload+28)==l->song.duration;
        if(valid){finish(l,LOAD_DONE,0);return true;}break;
    default:valid=false;break;
    }
    if(!valid){finish(l,l->state==LOAD_COMMIT||l->state==LOAD_VERIFY?LOAD_UNKNOWN:LOAD_FAILED,LIB_FORMAT);return true;}
    l->seq++;l->state=next;loader_poll(l,now);return true;
}
