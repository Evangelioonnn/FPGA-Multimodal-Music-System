#include "capture.h"
#define REG(a) (*(volatile uint32_t*)(a))
#define RCC_CR REG(0x40021000)
#define RCC_CFGR REG(0x40021004)
#define TIM2_REG(o) REG(0x40000000u+(o))
#define TIM4_REG(o) REG(0x40000800u+(o))
#define GPIOA_IDR REG(0x40010808)
#define GPIOB_BSRR REG(0x40010c10)
#define GPIOB_BRR REG(0x40010c14)
#define DMA1_ISR REG(0x40020000u)
/* RM0008: ISR +0x00, IFCR +0x04; +0x08 is channel 1 CCR, not IFCR. */
#define DMA1_IFCR REG(0x40020004u)
static dc_capture capture;
static volatile uint32_t timer_high;
static uint8_t row;
static uint8_t tx[128];
static uint8_t sending;
static uint32_t boot_cookie __attribute__((section(".noinit")));
static uint32_t boot_counter __attribute__((section(".noinit")));
static inline uint32_t lock(void){uint32_t p;__asm volatile("mrs %0, primask\ncpsid i":"=r"(p)::"memory");return p;}
static inline void unlock(uint32_t p){__asm volatile("msr primask,%0"::"r"(p):"memory");}
static uint32_t micros(void){
 uint32_t mask=lock(),hi=timer_high;uint16_t lo=(uint16_t)TIM2_REG(0x24);
 uint8_t pending=(uint8_t)(TIM2_REG(0x10)&1u);
 uint16_t again=(uint16_t)TIM2_REG(0x24);
 uint32_t result=dc_timer_read_result(hi,lo,pending,again);unlock(mask);return result;
}
void TIM2_IRQHandler(void){
 if(TIM2_REG(0x10)&1u){timer_high+=0x10000u;TIM2_REG(0x10)=~1u;}
}
void TIM4_IRQHandler(void){
 uint32_t at;uint8_t closed;
 if(!(TIM4_REG(0x10)&1u))return;
 TIM4_REG(0x10)=~1u;
 at=micros();closed=(uint8_t)~GPIOA_IDR; /* one port read, all eight columns */
 dc_sample(&capture,row,closed,at);
 GPIOB_BSRR=0xf000u;row=(uint8_t)((row+1u)&3u);GPIOB_BRR=1u<<(12u+row);
}
static void clock_init(void){
 RCC_CR|=1u;while(!(RCC_CR&2u)){}
 REG(0x40022000)=0x12u; /* prefetch, two wait states at 64 MHz */
 RCC_CFGR=(4u<<8)|(14u<<18); /* APB1 /2; HSI/2 *16; APB2 /1 */
 RCC_CR|=1u<<24;while(!(RCC_CR&(1u<<25))){}
 RCC_CFGR=(RCC_CFGR&~3u)|2u;while((RCC_CFGR&12u)!=8u){}
}
int main(void){
 uint32_t mask;dc_batch batch;unsigned n;
 clock_init();
 REG(0x40021018)|=(1u<<0)|(1u<<2)|(1u<<3)|(1u<<14);
 REG(0x4002101c)|=(1u<<0)|(1u<<2);REG(0x40021014)|=1u;
 GPIOB_BSRR=0xf000u;
 REG(0x40010800)=0x44444444u; /* PA0..7 digital floating input; external pullups */
 REG(0x40010c04)=(REG(0x40010c04)&0xffffu)|0x66660000u; /* PB12..15 OD 2 MHz */
 REG(0x40010804)=(REG(0x40010804)&~0xff0u)|0x8b0u;REG(0x40010810)=1u<<10;
 REG(0x40013808)=64u;REG(0x40013814)=1u<<7;REG(0x4001380c)=(1u<<13)|(1u<<3);
 if(boot_cookie!=0xdcc81234u){boot_cookie=0xdcc81234u;boot_counter=0;}
 boot_counter++;
 dc_init(&capture,boot_counter^REG(0x1ffff7e8)^REG(0x1ffff7ec)^REG(0x1ffff7f0));
 TIM2_REG(0x28)=63u;TIM2_REG(0x2c)=65535u;TIM2_REG(0x14)=1;TIM2_REG(0x10)=0;TIM2_REG(0x0c)=1;TIM2_REG(0)=1;
 row=0;GPIOB_BRR=1u<<12;
 TIM4_REG(0x28)=63u;TIM4_REG(0x2c)=24u;TIM4_REG(0x14)=1;TIM4_REG(0x10)=0;TIM4_REG(0x0c)=1;
 *(volatile uint8_t*)(0xe000e400u+28)=0;*(volatile uint8_t*)(0xe000e400u+30)=0x40;
 REG(0xe000e100)=(1u<<28)|(1u<<30);TIM4_REG(0)=1;
 for(;;){
  if(sending){
   if(!(DMA1_ISR&(1u<<13)))continue; /* DMA1 channel4 TCIF4 */
   DMA1_IFCR=15u<<12;REG(0x40020044)=0;sending=0;
  }
  mask=lock();n=(unsigned)dc_take(&capture,&batch);unlock(mask);
  if(!n)continue;
  n=dc_encode(&batch,tx); /* scan IRQs continue during CRC/escaping and UART */
  REG(0x40020044)=0;REG(0x40020048)=n;REG(0x4002004c)=0x40013804u;
  REG(0x40020050)=(uint32_t)tx;DMA1_IFCR=15u<<12;
  REG(0x40020044)=(1u<<4)|(1u<<7)|1u;sending=1;
 }
}
