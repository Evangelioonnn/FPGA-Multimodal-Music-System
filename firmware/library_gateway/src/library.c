#include "library.h"
#include <string.h>
#include <stdio.h>

static int rd(const struct lfs_config *c,lfs_block_t block,lfs_off_t off,void *p,lfs_size_t n){music_library *s=c->context;if(block>=NOR_BYTES/NOR_BLOCK||off>NOR_BLOCK||n>NOR_BLOCK-off)return LFS_ERR_INVAL;return s->nor.read(s->nor.ctx,block*NOR_BLOCK+off,p,n)?LFS_ERR_IO:0;}
static int pg(const struct lfs_config *c,lfs_block_t block,lfs_off_t off,const void *p,lfs_size_t n){music_library *s=c->context;if(block>=NOR_BYTES/NOR_BLOCK||off>NOR_BLOCK||n>NOR_BLOCK-off)return LFS_ERR_INVAL;return s->nor.program(s->nor.ctx,block*NOR_BLOCK+off,p,n)?LFS_ERR_IO:0;}
static int er(const struct lfs_config *c,lfs_block_t block){music_library *s=c->context;if(block>=NOR_BYTES/NOR_BLOCK)return LFS_ERR_INVAL;return s->nor.erase(s->nor.ctx,block*NOR_BLOCK)?LFS_ERR_IO:0;}
static int sy(const struct lfs_config *c){music_library *s=c->context;return s->nor.sync(s->nor.ctx)?LFS_ERR_IO:0;}
static void name(char *p,uint16_t id){snprintf(p,24,"/songs/%04X.fms",(unsigned)id);}
static const uint8_t owner_magic[8]={'F','M','S','L','I','B',1,0};
void library_init(music_library *s,const nor_device *nor){
    memset(s,0,sizeof(*s));s->nor=*nor;s->cfg.context=s;s->cfg.read=rd;s->cfg.prog=pg;s->cfg.erase=er;s->cfg.sync=sy;
    s->cfg.read_size=16;s->cfg.prog_size=256;s->cfg.block_size=NOR_BLOCK;s->cfg.block_count=NOR_BYTES/NOR_BLOCK;
    s->cfg.block_cycles=500;s->cfg.cache_size=256;s->cfg.lookahead_size=64;
    s->cfg.read_buffer=s->read_cache;s->cfg.prog_buffer=s->write_cache;s->cfg.lookahead_buffer=s->lookahead;
    s->file_cfg.buffer=s->file_cache;s->revision=1;
}
int library_format(music_library *s){
    if(s->mounted||s->writing)return LIB_BUSY;
    if(lfs_format(&s->fs,&s->cfg)||lfs_mount(&s->fs,&s->cfg))return LIB_IO;
    /* Directory creation belongs only to the explicitly requested format.
     * Normal startup mount must not create or repair a foreign directory. */
    int e=lfs_mkdir(&s->fs,"/songs");
    if(!e)e=lfs_setattr(&s->fs,"/",0x43,owner_magic,sizeof(owner_magic));
    int close=lfs_unmount(&s->fs);
    return e||close?LIB_IO:0;
}
typedef struct {music_library *s;lfs_file_t *file;} reader;
static int file_read(void *ctx,uint32_t off,void *buf,uint32_t n){reader *r=ctx;if(lfs_file_seek(&r->s->fs,r->file,(lfs_soff_t)off,LFS_SEEK_SET)!=(lfs_soff_t)off)return -1;return lfs_file_read(&r->s->fs,r->file,buf,n)==(lfs_ssize_t)n?0:-1;}
static int validate_file(music_library *s,const char *path,song_info *info){
    lfs_file_t f;uint8_t cache[256];struct lfs_file_config cfg={0};cfg.buffer=cache;
    if(lfs_file_opencfg(&s->fs,&f,path,LFS_O_RDONLY,&cfg))return LIB_IO;
    lfs_soff_t size=lfs_file_size(&s->fs,&f);reader r={s,&f};int e=size<0?LIB_IO:fms_validate(file_read,&r,(uint32_t)size,info);
    if(lfs_file_close(&s->fs,&f)&&!e)e=LIB_IO;return e;
}
int library_scan(music_library *s){
    if(!s->mounted)return LIB_NOT_MOUNTED;if(s->writing)return LIB_BUSY;
    lfs_dir_t dir;struct lfs_info entry;s->count=0;
    if(lfs_dir_open(&s->fs,&dir,"/songs"))return LIB_IO;
    int result=0,n;
    while((n=lfs_dir_read(&s->fs,&dir,&entry))>0){
        if(entry.type!=LFS_TYPE_REG||entry.name[0]=='.')continue;
        unsigned id=0;char expected[24],path[40];char extra;
        if(strlen(entry.name)!=8||sscanf(entry.name,"%4X.fms%c",&id,&extra)!=1||!id||id>65535)continue;
        name(expected,(uint16_t)id);if(strcmp(entry.name,expected+7))continue;
        name(path,(uint16_t)id);
        song_info info;int e=validate_file(s,path,&info);
        if(e==LIB_IO){result=e;break;}if(e||info.id!=id)continue;
        if(s->count==LIB_MAX_SONGS){result=LIB_FULL;break;}
        s->songs[s->count++]=info;
    }
    if(n<0)result=LIB_IO;if(lfs_dir_close(&s->fs,&dir))result=LIB_IO;
    for(unsigned i=1;i<s->count;i++){song_info v=s->songs[i];unsigned j=i;while(j&&s->songs[j-1].id>v.id){s->songs[j]=s->songs[j-1];j--;}s->songs[j]=v;}
    /* Opaque content revision survives reboot; do not rely on a RAM counter. */
    uint32_t revision=0;uint8_t identity[10];
    for(unsigned i=0;i<s->count;i++){music_put(identity,s->songs[i].id,2);music_put(identity+2,s->songs[i].size,4);music_put(identity+6,s->songs[i].crc,4);revision=music_crc32(revision,identity,10);}
    s->revision=revision?revision:1;
    s->last_error=result;return result;
}
int library_mount(music_library *s){
    if(s->mounted)return LIB_BUSY;int e=lfs_mount(&s->fs,&s->cfg);if(e)return LIB_NOT_MOUNTED;s->mounted=true;
    /* Never modify an existing foreign LittleFS, even if it has /songs.
     * Only our explicit format publishes the persistent owner/version tag. */
    uint8_t owner[sizeof(owner_magic)];
    if(lfs_getattr(&s->fs,"/",0x43,owner,sizeof(owner))!=(lfs_ssize_t)sizeof(owner)||memcmp(owner,owner_magic,sizeof(owner))){library_unmount(s);return LIB_NOT_MOUNTED;}
    /* Owned volumes may need rename/orphan recovery after an interrupted
     * save. A clean mount is read-only; this never creates a missing /songs. */
    if(lfs_fs_mkconsistent(&s->fs)){library_unmount(s);return LIB_IO;}
    struct lfs_info info;
    if(lfs_stat(&s->fs,"/songs",&info)||info.type!=LFS_TYPE_DIR){library_unmount(s);return LIB_IO;}
    return library_scan(s);
}
int library_unmount(music_library *s){if(!s->mounted)return LIB_NOT_MOUNTED;if(s->writing)return LIB_BUSY;int e=lfs_unmount(&s->fs);s->mounted=false;return e?LIB_IO:0;}
int library_begin(music_library *s,uint32_t task,uint16_t id,uint32_t size,uint32_t crc){
    if(!s->mounted)return LIB_NOT_MOUNTED;if(s->writing)return LIB_BUSY;
    if(!task||!id||size<1024||size>FMS_MAX_BYTES||(size&511))return LIB_RANGE;
    bool exists=false;for(unsigned i=0;i<s->count;i++)exists|=s->songs[i].id==id;
    if(!exists&&s->count==LIB_MAX_SONGS)return LIB_FULL;
    lfs_ssize_t used=lfs_fs_size(&s->fs);uint32_t blocks=(size+NOR_BLOCK-1)/NOR_BLOCK+12;
    if(used<0)return LIB_IO;if((uint32_t)used+blocks>s->cfg.block_count)return LIB_FULL;
    int e=lfs_file_opencfg(&s->fs,&s->incoming,"/incoming.part",LFS_O_WRONLY|LFS_O_CREAT|LFS_O_TRUNC,&s->file_cfg);if(e)return LIB_IO;
    s->writing=true;s->task=task;s->expected_id=id;s->expected_size=size;s->received=0;s->expected_crc=crc;s->rolling_crc=0;s->last_error=0;return 0;
}
int library_data(music_library *s,uint32_t task,uint32_t offset,const uint8_t *data,uint32_t n){
    if(!s->mounted)return LIB_NOT_MOUNTED;if(!s->writing||task!=s->task)return LIB_ID;
    if(s->last_error)return s->last_error;
    if(!n||n>512||!data||offset!=s->received||n>s->expected_size-s->received)return LIB_OFFSET;
    if(lfs_file_write(&s->fs,&s->incoming,data,n)!=(lfs_ssize_t)n)return s->last_error=LIB_IO;
    s->rolling_crc=music_crc32(s->rolling_crc,data,n);s->received+=n;return 0;
}
int library_abort(music_library *s,uint32_t task){
    if(!s->writing||task!=s->task)return LIB_ID;int e=lfs_file_close(&s->fs,&s->incoming);s->writing=false;
    int r=lfs_remove(&s->fs,"/incoming.part");return e||(r&&r!=LFS_ERR_NOENT)?LIB_IO:0;
}
int library_commit(music_library *s,uint32_t task){
    if(!s->writing||task!=s->task)return LIB_ID;
    if(s->last_error)return s->last_error;
    if(s->received!=s->expected_size)return LIB_OFFSET;
    if(s->rolling_crc!=s->expected_crc){library_abort(s,task);return LIB_CRC;}
    int e=lfs_file_sync(&s->fs,&s->incoming);int close=lfs_file_close(&s->fs,&s->incoming);s->writing=false;
    if(e||close)return LIB_IO;
    song_info info;e=validate_file(s,"/incoming.part",&info);
    if(e)return e;if(info.id!=s->expected_id||info.crc!=s->expected_crc)return LIB_ID;
    char path[24];name(path,info.id);
    if(lfs_rename(&s->fs,"/incoming.part",path))return LIB_IO;
    s->revision++;return library_scan(s);
}
int library_remove(music_library *s,uint16_t id){
    if(!s->mounted)return LIB_NOT_MOUNTED;if(s->writing)return LIB_BUSY;char path[24];name(path,id);
    int e=lfs_remove(&s->fs,path);if(e==LFS_ERR_NOENT)return LIB_NOT_FOUND;if(e)return LIB_IO;s->revision++;return library_scan(s);
}
int library_open(music_library *s,uint16_t id,lfs_file_t *f,struct lfs_file_config *cfg){
    if(!s->mounted)return LIB_NOT_MOUNTED;if(s->writing)return LIB_BUSY;
    bool found=false;for(unsigned i=0;i<s->count;i++)found|=s->songs[i].id==id;if(!found)return LIB_NOT_FOUND;
    char path[24];name(path,id);return lfs_file_opencfg(&s->fs,f,path,LFS_O_RDONLY,cfg)?LIB_IO:0;
}
