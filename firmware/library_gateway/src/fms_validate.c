#include "library.h"
#include <string.h>

uint16_t music_le16(const uint8_t *p){return (uint16_t)(p[0]|((uint16_t)p[1]<<8));}
uint32_t music_le32(const uint8_t *p){return (uint32_t)p[0]|((uint32_t)p[1]<<8)|((uint32_t)p[2]<<16)|((uint32_t)p[3]<<24);}
void music_put(uint8_t *p,uint32_t v,unsigned n){while(n--){*p++=(uint8_t)v;v>>=8;}}
uint32_t music_crc32(uint32_t crc,const void *data,size_t n){
    const uint8_t *p=data;crc=~crc;
    while(n--){crc^=*p++;for(unsigned k=0;k<8;k++)crc=(crc>>1)^((crc&1)?0xedb88320u:0);}
    return ~crc;
}
static bool zero(const uint8_t *p,unsigned n){while(n--)if(*p++)return false;return true;}
/* Strict terminated UTF-8, including overlong/surrogate/U+10ffff checks. */
static bool text(const uint8_t *p,unsigned n){
    unsigned i=0;
    while(i<n&&p[i]){
        uint32_t v=p[i++],min=0;unsigned count=0;
        if(v<0x80)continue;
        if(v>=0xc2&&v<=0xdf){v&=31;count=1;min=0x80;}
        else if(v>=0xe0&&v<=0xef){v&=15;count=2;min=0x800;}
        else if(v>=0xf0&&v<=0xf4){v&=7;count=3;min=0x10000;}
        else return false;
        while(count--){if(i>=n||(p[i]&0xc0)!=0x80)return false;v=(v<<6)|(p[i++]&63);}
        if(v<min||v>0x10ffff||(v>=0xd800&&v<=0xdfff))return false;
    }
    return i<n&&zero(p+i,n-i);
}
static int internal(unsigned p){if(p==0||p==3||p==4||p==5||p==6)return (int)p;if(p>=7&&p<=9)return 7;return p==10?1:-1;}
static unsigned gm(unsigned p){return p==3?14:(p==4||p==10)?81:p==7?27:p==8?30:p==9?33:0;}
static void field(uint8_t *out,uint32_t value,unsigned bit){while(value){if(value&1)out[bit/8]|=(uint8_t)(1u<<(bit%8));value>>=1;bit++;}}
static bool patch(const uint8_t *p,unsigned pub,unsigned release){
    uint8_t want[17]={0};unsigned in=(unsigned)internal(pub);
    field(want,10,132);field(want,1,130);field(want,in==7,127);
    field(want,pub>=7&&pub<=9?pub-7:0,125);field(want,2,118);field(want,release,115);
    field(want,3,99);field(want,32768,83);field(want,6,67);field(want,68,51);
    field(want,16,39);field(want,32,27);field(want,64,15);field(want,256,3);field(want,in,0);
    if(pub==10){want[0]=want[1]=want[2]=0;field(want,(32768u<<7)|(2u<<5)|(1u<<3)|1,0);}
    return memcmp(p,want,17)==0;
}
static uint32_t tail(unsigned preset,unsigned index){
    static const unsigned rate[8]={96,48,24,12,6,3,2,1};uint32_t frames;
    if(preset>=7){unsigned shift=index+9;if(shift>14)shift=14;
        uint32_t a=(49152u+(49152u>>shift))/(1u+(49152u>>shift));
        uint32_t b=(16384u+(16384u>>shift))/(1u+(16384u>>shift));frames=a>b?a:b;
    }else{uint32_t full=preset==3?16777215u:65535u,step=rate[index]*(preset==3?512u:1u);frames=(full+step-1)/step;}
    return (uint32_t)(((uint64_t)(frames+8)*1040+49)/50)+(preset==10?500000u:0);
}
static uint32_t drum_tail(unsigned pad){switch(pad){case 1:return 76045;case 5:return 60840;case 6:return 182895;case 7:return 473138;case 8:return 720013;default:return 119226;}}
typedef struct {uint16_t token;uint8_t track,note;uint32_t on,auto_end,slot_end;} voice;
int fms_validate(fms_read_fn read,void *ctx,uint32_t size,song_info *out){
    uint8_t h[512],b[512],seen[8192]={0};voice voices[32]={0};uint32_t drums[4]={0},main_end[25]={0};
    uint8_t role[4],pub[4],rel[4];unsigned mains=0,main_track=0;bool has_drums=false;
    uint32_t all_crc=0,event_crc=0;unsigned notes=0,main_notes=0,ap=0,dp=0,ip=0;
    if(!read||!out||size<512||size>FMS_MAX_BYTES||(size&511))return LIB_RANGE;
    if(read(ctx,0,h,512))return LIB_IO;
    if(memcmp(h,"FGMSNG1",8)||memcmp(h+52,"V7-MUS1",8)||music_le16(h+8)!=1||music_le16(h+10)||music_le16(h+12)!=512||music_le16(h+14)!=16)return LIB_FORMAT;
    uint32_t header_crc=music_le32(h+48);memset(h+48,0,4);
    if(music_crc32(0,h,512)!=header_crc)return LIB_CRC;
    music_put(h+48,header_crc,4);all_crc=music_crc32(0,h,512);
    uint32_t count=music_le32(h+16),duration=music_le32(h+20),end=music_le32(h+24),nominal=music_le32(h+28),caps=music_le32(h+192);
    unsigned nt=h[34],flags=h[35];
    if(!count||count>4096||!end||end>duration||duration==UINT32_MAX||((512+count*16+511)&~511u)!=size)return LIB_RANGE;
    if(!nt||nt>4||(flags&~31u)||(flags&3)!=3||h[32]<1||h[32]>12||h[33]<1||h[33]>4||nominal<100000||nominal>3000000)return LIB_FORMAT;
    if(music_le32(h+36)!=50000000||music_le16(h+40)!=1040||h[42]!=32||h[43]!=8||(caps&~7u)||(caps&3)!=3||!zero(h+196,60)||!music_le16(h+60)||music_le16(h+62)!=8249)return LIB_FORMAT;
    if(!text(h+64,48)||!text(h+112,48)||!text(h+160,32))return LIB_FORMAT;
    for(unsigned t=0;t<4;t++){
        const uint8_t *p=h+256+t*64;
        if(t>=nt){if(!zero(p,64))return LIB_FORMAT;continue;}
        role[t]=p[1];pub[t]=p[2];rel[t]=(p[22]>>3)&7;
        if(p[0]!=1||role[t]>3||internal(pub[t])<0||p[3]!=internal(pub[t])||music_le32(p+4)>65536)return LIB_FORMAT;
        if((role[t]==3)!=(pub[t]==6)||p[25]!=gm(pub[t])||p[26]!=(pub[t]==6?9:t)||!zero(p+27,5)||!text(p+32,32)||!patch(p+8,pub[t],rel[t]))return LIB_FORMAT;
        if(role[t]==0){mains++;main_track=t;}has_drums|=role[t]==3;
    }
    if(mains!=1||((flags&4)!=0)!=has_drums||((caps&4)!=0)!=has_drums)return LIB_FORMAT;
    uint32_t previous=0;int previous_priority=-1;bool ended=false;
    for(uint32_t offset=512;offset<size;offset+=512){
        if(read(ctx,offset,b,512))return LIB_IO;
        all_crc=music_crc32(all_crc,b,512);
        for(unsigned j=0;j<512;j+=16){
            uint32_t index=(offset-512+j)/16;uint8_t *e=b+j;
            if(index>=count){if(!zero(e,16))return LIB_FORMAT;continue;}
            event_crc=music_crc32(event_crc,e,16);
            uint32_t time=music_le32(e);unsigned token=music_le16(e+4),op=e[6],track=e[7],note=e[8],vel=e[9];
            int priority=op==2?0:op==1?1:op==3?2:op==127?3:-1;
            if(priority<0||!zero(e+10,6)||time>duration||time<previous||(time==previous&&priority<previous_priority))return LIB_FORMAT;
            previous=time;previous_priority=priority;
            for(unsigned k=0;k<32;k++)if(voices[k].auto_end<=time&&voices[k].slot_end<=time)memset(&voices[k],0,sizeof(voices[k]));
            if(op==127){
                if(index!=count-1||time!=duration||token||track||note||vel)return LIB_FORMAT;
                for(unsigned k=0;k<32;k++)if(voices[k].token)return LIB_RANGE;
                for(unsigned k=0;k<4;k++)if(drums[k]>time)return LIB_RANGE;
                ended=true;continue;
            }
            if(index==count-1||track>=nt||time>end)return LIB_FORMAT;
            if(op==3){
                if(role[track]!=3||token||!(note<=9||note==12||note==13)||!vel)return LIB_FORMAT;
                uint64_t expiry=(uint64_t)time+drum_tail(note);if(expiry>duration)return LIB_RANGE;
                unsigned k;for(k=0;k<4;k++)if(drums[k]<=time){drums[k]=(uint32_t)expiry;break;}if(k==4)return LIB_RANGE;
            }else{
                if(role[track]==3||!token)return LIB_FORMAT;
                if(op==1){
                    if(seen[token/8]&(1u<<(token%8)))return LIB_ID;
                    if(!vel||note<(internal(pub[track])==7?24:36)||note>84)return LIB_RANGE;
                    if(track==main_track){if(note<48||note>72||time<main_end[note-48]||++main_notes>2048)return LIB_RANGE;main_end[note-48]=UINT32_MAX;}
                    unsigned k;for(k=0;k<32;k++)if(!voices[k].token){voices[k]=(voice){(uint16_t)token,(uint8_t)track,(uint8_t)note,time,UINT32_MAX,UINT32_MAX};break;}
                    if(k==32)return LIB_RANGE;seen[token/8]|=(uint8_t)(1u<<(token%8));notes++;
                }else{
                    unsigned k;for(k=0;k<32;k++)if(voices[k].token==token&&voices[k].auto_end==UINT32_MAX)break;
                    if(k==32||voices[k].track!=track||voices[k].note!=note||vel!=255||time<=voices[k].on)return LIB_FORMAT;
                    uint32_t natural=tail(pub[track],rel[track]),slot=natural;
                    if(track==main_track&&slot<tail(0,3))slot=tail(0,3);
                    if((uint64_t)time+slot>duration||(uint64_t)time+natural>duration)return LIB_RANGE;
                    voices[k].auto_end=time+natural;voices[k].slot_end=time+slot;
                    if(track==main_track)main_end[note-48]=time;
                }
            }
            unsigned a=0,s=0,i=0,d=0;
            for(unsigned k=0;k<32;k++)if(voices[k].token){a+=voices[k].auto_end>time;s+=voices[k].slot_end>time;if(voices[k].slot_end>time)i+=voices[k].track==main_track?2:1;}
            for(unsigned k=0;k<4;k++)d+=drums[k]>time;
            if(a>12||s>12||i>16||d>4)return LIB_RANGE;
            if(a>ap)ap=a;if(i>ip)ip=i;if(d>dp)dp=d;
        }
    }
    if(!ended||!main_notes)return LIB_FORMAT;
    if(event_crc!=music_le32(h+44))return LIB_CRC;
    memset(out,0,sizeof(*out));out->id=music_le16(h+60);out->notes=(uint16_t)main_notes;
    out->size=size;out->crc=all_crc;out->duration=duration;out->events=count;out->tracks=(uint8_t)nt;
    out->auto_peak=(uint8_t)ap;out->drum_peak=(uint8_t)dp;out->interactive_peak=(uint8_t)ip;memcpy(out->title,h+64,48);
    (void)notes;return LIB_OK;
}
