/* Candidate WeAct F411 board port. Internal HSI 16MHz: no crystal assumption.
 * Register layout follows STM32F411 reference manual RM0383. No audio synthesis.
 * PROBE build never enables external-Flash writes. Neither build autoformats.
 */
#include "gateway.h"
#include "spi_nor.h"
#include <string.h>
#ifndef LIBRARY_WRITES
#define LIBRARY_WRITES 0
#endif
#define REG(a) (*(volatile uint32_t *)(a))
#define RCC 0x40023800u
#define GPIOA 0x40020000u
#define GPIOB 0x40020400u
#define USART1 0x40011000u
#define USART2 0x40004400u
#define SPI1 0x40013000u
#define RX_SIZE 2048u
typedef struct {volatile uint16_t head,tail;volatile uint32_t errors;uint8_t data[RX_SIZE];} rx_ring;
static rx_ring rings[2];static volatile uint32_t ticks;
static music_library storage;static music_gateway gateway;static spi_nor flash;
static wire_decoder decoders[2];
/* Exposed in SWD debugger; no printf on protocol UARTs. */
volatile struct {uint32_t jedec,ms,rx_errors[2],malformed[2],tx_errors,assert_line;int flash_probe,mount;
    uint32_t magic,version,writes_enabled,phone_state,rx_bytes[2],tx_frames[2];
    uint32_t flash_head_crc,flash_tail_crc,flash_reads;int flash_read_probe;} diagnostics;
/* Retain LittleFS assertions in the microlib build; do not print onto UART. */
void __aeabi_assert(const char *expression,const char *file,int line){(void)expression;(void)file;diagnostics.assert_line=(uint32_t)line;for(;;){}}
#ifdef __GNUC__
void __assert_func(const char *file,int line,const char *function,const char *expression){(void)function;__aeabi_assert(expression,file,line);for(;;){}}
#endif

void SysTick_Handler(void){ticks++;}
static void receive(unsigned port,uint32_t base){
    uint32_t sr=REG(base);if(sr&0x2fu){uint8_t byte=(uint8_t)REG(base+4);rx_ring *r=&rings[port];
        if(sr&15){r->errors++;return;}uint16_t next=(uint16_t)((r->head+1)&(RX_SIZE-1));
        if(next==r->tail){r->errors++;return;}r->data[r->head]=byte;r->head=next;diagnostics.rx_bytes[port]++;
    }
}
void USART1_IRQHandler(void){receive(PORT_PHONE,USART1);}
void USART2_IRQHandler(void){receive(PORT_FPGA,USART2);}
static uint32_t millis(void *ctx){(void)ctx;return ticks;}
static int wait_bits(uint32_t address,uint32_t mask,bool set,uint32_t timeout){uint32_t start=ticks;
    while(((REG(address)&mask)!=0)!=set)if((uint32_t)(ticks-start)>=timeout)return -1;return 0;}
static int chip_select(void *ctx,bool on){(void)ctx;int e=wait_bits(SPI1+8,128,false,20);REG(GPIOA+0x18)=1u<<(!e&&on?20:4);return e;}
static int transfer(void *ctx,uint8_t tx,uint8_t *rx){
    (void)ctx;if(wait_bits(SPI1+8,2,true,20))return -1;*(volatile uint8_t *)(SPI1+12)=tx;
    if(wait_bits(SPI1+8,1,true,20))return -1;*rx=*(volatile uint8_t *)(SPI1+12);return 0;
}
static int send_frame(void *ctx,unsigned port,const music_frame *frame){
    (void)ctx;uint8_t bytes[154];size_t n=wire_encode(frame,bytes);uint32_t base=port==PORT_PHONE?USART1:USART2;
    for(size_t i=0;i<n;i++){if(wait_bits(base,128,true,50)){diagnostics.tx_errors++;return -1;}REG(base+4)=bytes[i];}diagnostics.tx_frames[port]++;return 0;
}
static void gpio_af(unsigned pin,unsigned af){
    REG(GPIOA)=(REG(GPIOA)&~(3u<<(pin*2)))|(2u<<(pin*2));
    REG(GPIOA+0x20+(pin/8)*4)=(REG(GPIOA+0x20+(pin/8)*4)&~(15u<<((pin%8)*4)))|(af<<((pin%8)*4));
    REG(GPIOA+8)|=3u<<(pin*2);
}
static void board_init(void){
    /* Reset-compatible HSI, no PLL. Candidate firmware assumes normal reset entry. */
    REG(RCC)|=1;while(!(REG(RCC)&2)){}REG(RCC+8)=0;while(REG(RCC+8)&12){}
    REG(RCC+0x30)|=3;REG(RCC+0x40)|=1u<<17;REG(RCC+0x44)|=(1u<<4)|(1u<<12);(void)REG(RCC+0x44);
    gpio_af(2,7);gpio_af(3,7);gpio_af(9,7);gpio_af(10,7);gpio_af(5,5);gpio_af(6,5);gpio_af(7,5);
    /* Idle-high RX lines remain quiet while the external modules are absent. */
    REG(GPIOA+0x0c)=(REG(GPIOA+0x0c)&~((3u<<6)|(3u<<20)))|(1u<<6)|(1u<<20);
    REG(GPIOA+0x18)=1u<<4;REG(GPIOA)=(REG(GPIOA)&~(3u<<8))|(1u<<8);
    /* Optional STATE fanout to PB1, input with pulldown. Keep original AB21 input. */
    REG(GPIOB)&=~(3u<<2);REG(GPIOB+0x0c)=(REG(GPIOB+0x0c)&~(3u<<2))|(2u<<2);
    REG(SPI1)= (1u<<2)|(3u<<3)|(1u<<8)|(1u<<9)|(1u<<6); /* Mode0, 1MHz. */
    REG(USART1+8)=139;REG(USART2+8)=139;
    REG(USART1+12)=(1u<<13)|(1u<<5)|(1u<<3)|(1u<<2);REG(USART2+12)=REG(USART1+12);
    REG(0xe000e104u)=(1u<<5)|(1u<<6); /* USART1 IRQ37, USART2 IRQ38. */
    REG(0xe000e014u)=15999;REG(0xe000e018u)=0;REG(0xe000e010u)=7;
}
int main(void){
    board_init();diagnostics.magic=0x434c4942u;diagnostics.version=0x00010001u;diagnostics.writes_enabled=LIBRARY_WRITES!=0;
    flash.ctx=NULL;flash.select=chip_select;flash.transfer=transfer;flash.millis=millis;flash.write_enabled=LIBRARY_WRITES!=0;
    diagnostics.flash_probe=spi_nor_detect(&flash);diagnostics.jedec=flash.jedec;
    diagnostics.flash_read_probe=-1;
    if(diagnostics.flash_probe==0){
        /* Read-only bring-up: compare two reads at each end of the array.
         * Never infer "blank" or permit format from these small samples. */
        uint8_t a[64],b[64];bool ok=true;
        for(unsigned end=0;end<2;end++){
            uint32_t at=end?NOR_BYTES-64:0;
            if(spi_nor_read(&flash,at,a,64)||spi_nor_read(&flash,at,b,64)||memcmp(a,b,64))ok=false;
            else{diagnostics.flash_reads+=2;if(end)diagnostics.flash_tail_crc=music_crc32(0,a,64);else diagnostics.flash_head_crc=music_crc32(0,a,64);}
        }
        diagnostics.flash_read_probe=ok?0:-1;
    }
    nor_device device=spi_nor_device(&flash);library_init(&storage,&device);
    diagnostics.mount=LIB_NOT_MOUNTED;
    if(LIBRARY_WRITES&&diagnostics.flash_probe==0&&diagnostics.flash_read_probe==0)diagnostics.mount=library_mount(&storage);
    uint32_t nonce=REG(0x1fff7a10u)^REG(0x1fff7a14u)^REG(0x1fff7a18u)^0x4c465331u;
    gateway_init(&gateway,&storage,nonce,NULL,send_frame);
    gateway.flash_jedec=flash.jedec;
    gateway.write_allowed=LIBRARY_WRITES!=0&&diagnostics.flash_probe==0&&diagnostics.flash_read_probe==0;
    bool previous_state=false;uint32_t error_seen[2]={0};
    for(;;){
        bool state=(REG(GPIOB+0x10)&2)!=0;if(state)gateway.connected=true;if(previous_state&&!state)gateway_disconnected(&gateway);previous_state=state;
        diagnostics.phone_state=state;
        for(unsigned port=0;port<2;port++){
            rx_ring *r=&rings[port];if(r->errors!=error_seen[port]){error_seen[port]=r->errors;memset(&decoders[port],0,sizeof(decoders[port]));gateway_disconnected(&gateway);}
            unsigned budget=256;
            while(r->tail!=r->head&&budget--){uint8_t byte=r->data[r->tail];r->tail=(uint16_t)((r->tail+1)&(RX_SIZE-1));music_frame frame;
                if(wire_feed(&decoders[port],byte,ticks,&frame)){
                    if(port==PORT_PHONE)gateway_phone(&gateway,&frame,ticks);else gateway_fpga(&gateway,&frame,ticks);
                }
            }
            diagnostics.rx_errors[port]=r->errors;diagnostics.malformed[port]=decoders[port].malformed;
        }
        gateway_poll(&gateway,ticks);diagnostics.ms=ticks;
    }
}
