#ifndef MUSIC_LOADER_H
#define MUSIC_LOADER_H
#include "library.h"
#include "wire.h"
enum { LOAD_IDLE,LOAD_CAPS,LOAD_STATUS,LOAD_LIVE,LOAD_RECORD,LOAD_BEGIN,LOAD_DATA,LOAD_COMMIT,LOAD_VERIFY,LOAD_DONE,LOAD_FAILED,LOAD_UNKNOWN };
typedef struct {
    music_library *library;lfs_file_t file;struct lfs_file_config cfg;uint8_t cache[256];
    void *ctx;int (*send)(void *,const music_frame *);
    music_frame pending;uint16_t seq;uint32_t session,task,offset,deadline,generation;
    song_info song;uint8_t state,retries;bool waiting,opened;int error;
} music_loader;
void loader_init(music_loader *l,music_library *s,void *ctx,int (*send)(void *,const music_frame *));
int loader_start(music_loader *l,uint16_t id,uint32_t session,uint32_t task,uint32_t now);
void loader_poll(music_loader *l,uint32_t now);
bool loader_accept(music_loader *l,const music_frame *reply,uint32_t now);
bool loader_busy(const music_loader *l);
#endif
