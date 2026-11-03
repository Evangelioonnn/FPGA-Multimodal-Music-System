#ifndef MUSIC_WIRE_H
#define MUSIC_WIRE_H
#include <stdint.h>
#include <stddef.h>
#include <stdbool.h>
#define WIRE_MAX 64
typedef struct {uint8_t command,len,payload[WIRE_MAX];uint16_t seq;uint32_t session;} music_frame;
typedef struct {uint8_t raw[76];unsigned n,malformed,timeouts;bool active,escape,discard;uint32_t last_ms;} wire_decoder;
uint16_t wire_crc16(const uint8_t *p,size_t n);
size_t wire_encode(const music_frame *f,uint8_t out[154]);
bool wire_feed(wire_decoder *d,uint8_t byte,uint32_t now,music_frame *out);
typedef struct {bool valid;music_frame request,response;} wire_replay;
/* 1 exact retry, -1 same sequence with altered bytes, 0 new request. */
int wire_retry(const wire_replay *r,const music_frame *f);
void wire_remember(wire_replay *r,const music_frame *q,const music_frame *a);
#endif
