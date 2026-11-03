#ifndef MUSIC_GATEWAY_H
#define MUSIC_GATEWAY_H
#include "loader.h"
enum { PORT_PHONE=0,PORT_FPGA=1 };
typedef struct {
    music_library *library;music_loader loader;
    void *ctx;int (*send)(void *,unsigned,const music_frame *);
    wire_replay extension,screen_load;music_frame in_flight;bool pending,owned,connected,loader_result_seen,write_allowed,screen_owned;
    bool status_safe,live_safe,record_safe;uint32_t status_at,live_at,record_at;
    uint32_t now,extension_session,last_owner_at,boot_nonce,flash_jedec,load_session_cursor;uint16_t extension_next;
    uint16_t loaded_id;uint32_t loaded_generation,loaded_crc,phone_upload_crc;
} music_gateway;
void gateway_init(music_gateway *g,music_library *s,uint32_t boot_nonce,void *ctx,int (*send)(void *,unsigned,const music_frame *));
void gateway_phone(music_gateway *g,const music_frame *p,uint32_t now);
void gateway_fpga(music_gateway *g,const music_frame *p,uint32_t now);
void gateway_poll(music_gateway *g,uint32_t now);
/* Called on a confirmed falling STATE edge or explicit transport disconnect. */
void gateway_disconnected(music_gateway *g);
void gateway_screen(music_gateway *g,const music_frame *p,uint32_t now);
#endif
