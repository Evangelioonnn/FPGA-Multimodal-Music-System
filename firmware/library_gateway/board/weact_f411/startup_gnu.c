#include <stdint.h>
extern uint32_t _sidata,_sdata,_edata,_sbss,_ebss,_estack;
extern int main(void);
extern void SysTick_Handler(void),USART1_IRQHandler(void),USART2_IRQHandler(void);
static void fault(void){for(;;){}}
void Reset_Handler(void){
    uint32_t *src=&_sidata;for(uint32_t *p=&_sdata;p<&_edata;p++)*p=*src++;
    for(uint32_t *p=&_sbss;p<&_ebss;p++)*p=0;
    (void)main();for(;;){}
}
typedef void (*handler)(void);
__attribute__((section(".isr_vector"),used)) const handler vectors[102]={
    [0]=(handler)&_estack,[1]=Reset_Handler,[2]=fault,[3]=fault,[4]=fault,[5]=fault,[6]=fault,
    [11]=fault,[12]=fault,[14]=fault,[15]=SysTick_Handler,
    [16 ... 52]=fault,[53]=USART1_IRQHandler,[54]=USART2_IRQHandler,[55 ... 101]=fault
};
