#ifndef MUSIC_LIBRARY_H
#define MUSIC_LIBRARY_H
#include <stdint.h>
#include <stddef.h>
#include <stdbool.h>
#include "lfs.h"

#define LIB_MAX_SONGS 32
#define FMS_MAX_BYTES 66048u
#define NOR_BYTES (8u*1024u*1024u)
#define NOR_BLOCK 4096u

enum { LIB_OK=0, LIB_IO=-1, LIB_FORMAT=-2, LIB_CRC=-3, LIB_RANGE=-4,
       LIB_BUSY=-5, LIB_OFFSET=-6, LIB_NOT_FOUND=-7, LIB_FULL=-8,
       LIB_NOT_MOUNTED=-9, LIB_ID=-10 };
typedef int (*fms_read_fn)(void *,uint32_t,void *,uint32_t);
typedef struct {
    uint16_t id,notes; uint32_t size,crc,duration,events;
    uint8_t tracks,auto_peak,drum_peak,interactive_peak;
    char title[48];
} song_info;
uint32_t music_crc32(uint32_t crc,const void *data,size_t n);
int fms_validate(fms_read_fn read,void *ctx,uint32_t size,song_info *info);
uint16_t music_le16(const uint8_t *p);
uint32_t music_le32(const uint8_t *p);
void music_put(uint8_t *p,uint32_t v,unsigned n);

typedef struct {
    void *ctx;
    int (*read)(void *,uint32_t,void *,uint32_t);
    int (*program)(void *,uint32_t,const void *,uint32_t);
    int (*erase)(void *,uint32_t);
    int (*sync)(void *);
} nor_device;
typedef struct {
    lfs_t fs; struct lfs_config cfg; nor_device nor;
    uint8_t read_cache[256],write_cache[256],lookahead[64];
    uint8_t file_cache[256]; struct lfs_file_config file_cfg;
    lfs_file_t incoming; bool mounted,writing;
    uint32_t expected_size,received,expected_crc,rolling_crc,task,revision;
    uint16_t expected_id; int last_error;
    song_info songs[LIB_MAX_SONGS]; uint8_t count;
} music_library;
void library_init(music_library *s,const nor_device *nor);
/* No automatic formatting on mount failure. Explicit provisioning only. */
int library_format(music_library *s);
int library_mount(music_library *s);
int library_unmount(music_library *s);
int library_scan(music_library *s);
int library_begin(music_library *s,uint32_t task,uint16_t id,uint32_t size,uint32_t crc);
int library_data(music_library *s,uint32_t task,uint32_t offset,const uint8_t *data,uint32_t n);
int library_commit(music_library *s,uint32_t task);
int library_abort(music_library *s,uint32_t task);
int library_remove(music_library *s,uint16_t id);
int library_open(music_library *s,uint16_t id,lfs_file_t *file,struct lfs_file_config *cfg);
#endif
