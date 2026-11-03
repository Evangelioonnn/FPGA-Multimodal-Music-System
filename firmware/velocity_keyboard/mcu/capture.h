#ifndef DCL_CAPTURE_H
#define DCL_CAPTURE_H
#include <stdint.h>
#define DC_QUEUE 512u
#define DC_REBASE 1u
#define DC_OVERFLOW 2u
#define DC_TIMING 4u
typedef struct { uint32_t time; uint8_t row,bits,kind,pad; } dc_record;
typedef struct {
 dc_record q[DC_QUEUE],latest[4];
 uint16_t head,tail,seq;
 uint32_t session,samples,overflows,timing_faults,max_gap,last_time;
 uint8_t valid,started,needs_rebase,fault_flags,snapshot_div;
} dc_capture;
typedef struct {
 uint32_t session; uint16_t seq;
 uint8_t type,flags,count;
 dc_record records[8];
} dc_batch;
void dc_init(dc_capture *c,uint32_t session);
void dc_sample(dc_capture *c,uint8_t row,uint8_t closed,uint32_t time);
/* Caller serializes take against the sample ISR. Encoding is outside IRQ masking. */
int dc_take(dc_capture *c,dc_batch *b);
unsigned dc_encode(const dc_batch *b,uint8_t out[128]);
uint16_t dc_crc(const uint8_t *data,unsigned size);
uint32_t dc_timer_read_result(uint32_t high,uint16_t first,uint8_t overflow,uint16_t second);
#endif
